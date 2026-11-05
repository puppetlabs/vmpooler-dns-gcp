require 'spec_helper'
require 'mock_redis'
require 'vmpooler/dns/gcp'

describe 'Vmpooler::PoolManager::Dns::Gcp' do
  let(:logger) { MockLogger.new }
  let(:metrics) { Vmpooler::Metrics::DummyStatsd.new }
  let(:poolname) { 'debian-9' }
  let(:options) { { 'param' => 'value' } }
  let(:name) { 'gcp' }
  let(:zone_name) { 'vmpooler-example-com' }
  let(:config) { YAML.load(<<~EOT
  ---
  :config:
    max_tries: 3
    retry_factor: 10
  :dns_configs:
    :#{name}:
      dns_class: gcp
      project: vmpooler-example
      domain: vmpooler.example.com
      zone_name: vmpooler-example-com
      dns_zone_resource_name: vmpooler-example-com
  :providers:
    :dummy:
      filename: '/tmp/dummy-backing.yaml'
  :pools:
    - name: '#{poolname}'
      alias: [ 'mockpool' ]
      template: 'Templates/debian-9-x86_64'
      size: 5
      timeout: 10
      ready_ttl: 1440
      provider: 'dummy'
      dns_config: '#{name}'
EOT
    )
  }

  let(:vmname) { 'spicy-proton' }
  let(:connection_options) {{}}
  let(:connection) { mock_Google_Cloud_Dns_Project_Connection(connection_options) }
  let(:redis_connection_pool) do
    Vmpooler::PoolManager::GenericConnectionPool.new(
      metrics: metrics,
      connpool_type: 'redis_connection_pool',
      connpool_provider: 'testprovider',
      size: 1,
      timeout: 5
    ) { MockRedis.new }
  end

  subject { Vmpooler::PoolManager::Dns::Gcp.new(config, logger, metrics, redis_connection_pool, name, options) }

  describe '#name' do
    it 'should be gcp' do
      expect(subject.name).to eq('gcp')
    end
  end

  describe '#project' do
    it 'should be the project specified in the dns config' do
      expect(subject.project).to eq('vmpooler-example')
    end
  end

  describe '#zone_name' do
    it 'should be the zone_name specified in the dns config' do
      expect(subject.zone_name).to eq('vmpooler-example-com')
    end
  end

  describe '#create_or_replace_record' do
    let(:hostname) { 'spicy-proton' }
    let(:zone) { MockDnsZone.new }
    let(:ip) { '169.254.255.255' }
    let(:already_exists) { Google::Cloud::AlreadyExistsError.new('MockError') }
    let(:precondition) { Google::Cloud::FailedPreconditionError.new('MockError') }

    before(:each) do
      allow(Google::Cloud::Dns).to receive(:configure)
      allow(Google::Cloud::Dns).to receive(:new).and_return(connection)
      allow(connection).to receive(:zone).and_return(zone)
      allow(subject).to receive(:get_ip).and_return(ip)
      allow(subject).to receive(:sleep)
    end

    # Calls of #replace answer in turn: an exception is raised, anything else is returned.
    def replace_answers(*answers)
      calls = 0
      allow(zone).to receive(:replace) do |*_args, **_opts|
        answer = answers[[calls, answers.length - 1].min]
        calls += 1
        raise answer if answer.is_a?(Exception)

        answer
      end
    end

    it 'sets the record with one change that skips the SOA bump' do
      expect(zone).to receive(:replace).with(hostname, 'A', 60, ip, skip_soa: true).once
      subject.create_or_replace_record(hostname)
    end

    it 'never adds the record on its own, which fails when the record exists' do
      allow(zone).to receive(:replace)
      expect(zone).not_to receive(:add)
      subject.create_or_replace_record(hostname)
    end

    it 'does nothing when the library finds nothing to change' do
      replace_answers(nil)
      expect { subject.create_or_replace_record(hostname) }.not_to raise_error
    end

    it 'does not try again when the change works' do
      expect(zone).to receive(:replace).once
      expect(subject).not_to receive(:sleep)
      subject.create_or_replace_record(hostname)
    end

    context 'when the record appears after we looked' do
      it 'tries again from a fresh read and succeeds' do
        replace_answers(already_exists, nil)
        expect(zone).to receive(:replace).twice
        expect { subject.create_or_replace_record(hostname) }.not_to raise_error
      end
    end

    context 'when another change to the zone wins the race' do
      it 'tries again and succeeds' do
        replace_answers(precondition, nil)
        expect(zone).to receive(:replace).twice
        expect { subject.create_or_replace_record(hostname) }.not_to raise_error
      end
    end

    # The failure seen in production (P4DEVOPS-16408): AlreadyExistsError, then FailedPreconditionError while
    # handling it, which escaped and failed the clone.
    context 'when both errors happen one after the other' do
      it 'carries on until the change works, and nothing escapes' do
        replace_answers(already_exists, precondition, already_exists, nil)
        expect(zone).to receive(:replace).exactly(4).times
        expect { subject.create_or_replace_record(hostname) }.not_to raise_error
      end
    end

    context 'when the change keeps failing' do
      it 'gives up after MAX_ATTEMPTS and raises the last error, waiting between tries' do
        replace_answers(precondition)
        expect(zone).to receive(:replace).exactly(Vmpooler::PoolManager::Dns::Gcp::MAX_ATTEMPTS).times
        expect(subject).to receive(:sleep).exactly(Vmpooler::PoolManager::Dns::Gcp::MAX_ATTEMPTS - 1).times
        expect { subject.create_or_replace_record(hostname) }.to raise_error(Google::Cloud::FailedPreconditionError)
      end

      it 'lets an error that is not a race through at once' do
        replace_answers(Google::Cloud::PermissionDeniedError.new('MockError'))
        expect(zone).to receive(:replace).once
        expect(subject).not_to receive(:sleep)
        expect { subject.create_or_replace_record(hostname) }.to raise_error(Google::Cloud::PermissionDeniedError)
      end
    end

    it 'counts and logs each retry upstream, so it can be seen' do
      replace_answers(already_exists, precondition, nil)
      allow(logger).to receive(:log) # the connection pool logs too
      allow(metrics).to receive(:increment) # and counts connections
      expect(metrics).to receive(:increment).with('dns.gcp.retry').twice
      expect(logger).to receive(:log).with('[g]', /create_or_replace_record spicy-proton: Google::Cloud::AlreadyExistsError, attempt 1 of 5/)
      expect(logger).to receive(:log).with('[g]', /Google::Cloud::FailedPreconditionError, attempt 2 of 5/)
      subject.create_or_replace_record(hostname)
    end

    it 'waits longer after each failed attempt' do
      replace_answers(precondition, precondition, nil)
      waits = []
      allow(subject).to receive(:sleep) { |seconds| waits << seconds }
      subject.create_or_replace_record(hostname)
      expect(waits.length).to eq(2)
      expect(waits[0]).to be_between(1, 2)
      expect(waits[1]).to be_between(2, 3)
    end

    context 'when IP does not exist' do
      let(:ip) { nil }

      it 'should not attempt to change a record' do
        expect(zone).not_to receive(:replace)
        expect(zone).not_to receive(:add)
        subject.create_or_replace_record(hostname)
      end
    end
  end

  describe '#delete_record' do
    let(:hostname) { 'spicy-proton' }
    let(:zone) { MockDnsZone.new }
    let(:precondition) { Google::Cloud::FailedPreconditionError.new('MockError') }

    before(:each) do
      allow(Google::Cloud::Dns).to receive(:configure)
      allow(Google::Cloud::Dns).to receive(:new).and_return(connection)
      allow(connection).to receive(:zone).and_return(zone)
      allow(subject).to receive(:sleep)
    end

    it 'removes the record with one change that skips the SOA bump' do
      expect(zone).to receive(:remove).with(hostname, 'A', skip_soa: true).once
      subject.delete_record(hostname)
    end

    it 'tries again when another change wins the race, and then works' do
      calls = 0
      allow(zone).to receive(:remove) do |*_args, **_opts|
        calls += 1
        raise precondition if calls == 1
      end
      expect { subject.delete_record(hostname) }.not_to raise_error
      expect(calls).to eq(2)
    end

    context 'when the change keeps failing' do
      it 'gives up after MAX_ATTEMPTS, logs it and does not raise' do
        allow(zone).to receive(:remove).and_raise(precondition)
        allow(logger).to receive(:log) # the connection pool and every retry log too
        allow(metrics).to receive(:increment) # and the pool counts connections
        expect(zone).to receive(:remove).exactly(Vmpooler::PoolManager::Dns::Gcp::MAX_ATTEMPTS).times
        expect(metrics).to receive(:increment).with('dns.gcp.retry').exactly(Vmpooler::PoolManager::Dns::Gcp::MAX_ATTEMPTS - 1).times
        expect(metrics).to receive(:increment).with('dns.gcp.delete_gave_up').once
        expect(logger).to receive(:log).with('[g]', /delete_record spicy-proton gave up after 5 attempts/)
        expect { subject.delete_record(hostname) }.not_to raise_error
      end
    end

    it 'lets an error that is not a race through' do
      allow(zone).to receive(:remove).and_raise(Google::Cloud::PermissionDeniedError.new('MockError'))
      expect { subject.delete_record(hostname) }.to raise_error(Google::Cloud::PermissionDeniedError)
    end
  end

  describe '#ensured_gcp_connection' do
    let(:connection1) { mock_Google_Cloud_Dns_Project_Connection(connection_options) }
    let(:connection2) { mock_Google_Cloud_Dns_Project_Connection(connection_options) }

    before(:each) do
      allow(subject).to receive(:connect_to_gcp).and_return(connection1)
    end

    it 'should return the same connection object when calling the pool multiple times' do
      subject.connection_pool.with_metrics do |pool_object|
        expect(pool_object[:connection]).to be(connection1)
      end
      subject.connection_pool.with_metrics do |pool_object|
        expect(pool_object[:connection]).to be(connection1)
      end
      subject.connection_pool.with_metrics do |pool_object|
        expect(pool_object[:connection]).to be(connection1)
      end
    end

    context 'when the connection breaks' do
      before(:each) do
        # Emulate the connection state being good, then bad, then good again
        expect(subject).to receive(:gcp_connection_ok?).and_return(true, false, true)
        expect(subject).to receive(:connect_to_gcp).and_return(connection1, connection2)
      end

      it 'should restore the connection' do
        subject.connection_pool.with_metrics do |pool_object|
          # This line needs to be added to all instances of the connection_pool allocation
          connection = subject.ensured_gcp_connection(pool_object)

          expect(connection).to be(connection1)
        end

        subject.connection_pool.with_metrics do |pool_object|
          connection = subject.ensured_gcp_connection(pool_object)
          # The second connection would have failed.  This test ensures that a
          # new connection object was created.
          expect(connection).to be(connection2)
        end

        subject.connection_pool.with_metrics do |pool_object|
          connection = subject.ensured_gcp_connection(pool_object)
          expect(connection).to be(connection2)
        end
      end
    end
  end

  describe '#connect_to_gcp' do
    before(:each) do
      allow(Google::Cloud::Dns).to receive(:configure)
      allow(Google::Cloud::Dns).to receive(:new).and_return(connection)
    end

    context 'successful connection' do
      it 'should return the connection object' do
        result = subject.connect_to_gcp

        expect(result).to be(connection)
      end

      it 'should increment the connect.open counter' do
        expect(metrics).to receive(:increment).with('connect.open')
        subject.connect_to_gcp
      end
    end

    context 'connection is initially unsuccessful' do
      before(:each) do
        # Simulate a failure and then success
        allow(Google::Cloud::Dns).to receive(:configure)
        expect(Google::Cloud::Dns).to receive(:new).and_raise(RuntimeError,'MockError')
        allow(subject).to receive(:sleep)
      end

      it 'should return the connection object' do
        result = subject.connect_to_gcp

        expect(result).to be(connection)
      end

      it 'should increment the connect.fail and then connect.open counter' do
        expect(metrics).to receive(:increment).with('connect.fail').exactly(1).times
        expect(metrics).to receive(:increment).with('connect.open').exactly(1).times
        subject.connect_to_gcp
      end
    end

    context 'connection is always unsuccessful' do
      before(:each) do
        allow(Google::Cloud::Dns).to receive(:configure)
        allow(Google::Cloud::Dns).to receive(:new).exactly(3).times.and_raise(RuntimeError,'MockError')
        allow(subject).to receive(:sleep)
      end

      it 'should retry the connection attempt config.max_tries times' do
        expect(Google::Cloud::Dns).to receive(:new).exactly(config[:config]['max_tries']).times

        begin
          # Swallow any errors
          subject.connect_to_gcp
        rescue
        end
      end

      it 'should increment the connect.fail counter config.max_tries times' do
        expect(metrics).to receive(:increment).with('connect.fail').exactly(config[:config]['max_tries']).times

        begin
          # Swallow any errors
          subject.connect_to_gcp
        rescue
        end
      end
    end
  end
end
