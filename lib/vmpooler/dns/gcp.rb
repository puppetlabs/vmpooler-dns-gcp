# frozen_string_literal: true

require 'googleauth'
require 'google/cloud/dns'
require 'vmpooler/dns/base'

module Vmpooler
  class PoolManager
    class Dns
      # This class represent a DNS plugin to CRUD resources in Google Cloud DNS.
      class Gcp < Vmpooler::PoolManager::Dns::Base
        # The connection_pool method is normally used only for testing
        attr_reader :connection_pool

        def initialize(config, logger, metrics, redis_connection_pool, name, options)
          super(config, logger, metrics, redis_connection_pool, name, options)

          task_limit = global_config[:config].nil? || global_config[:config]['task_limit'].nil? ? 10 : global_config[:config]['task_limit'].to_i

          default_connpool_size = [provided_pools.count, task_limit, 2].max
          connpool_timeout = 60
          logger.log('d', "[#{name}] ConnPool - Creating a connection pool of size #{default_connpool_size} with timeout #{connpool_timeout}")
          @connection_pool = Vmpooler::PoolManager::GenericConnectionPool.new(
            metrics: metrics,
            connpool_type: 'dns_connection_pool',
            connpool_provider: name,
            size: default_connpool_size,
            timeout: connpool_timeout
          ) do
            logger.log('d', "[#{name}] Connection Pool - Creating a connection object")
            # Need to wrap the GCP connection object in another object. The generic connection pooler will preserve
            # the object reference for the connection, which means it cannot "reconnect" by creating an entirely new connection
            # object.  Instead by wrapping it in a Hash, the Hash object reference itself never changes but the content of the
            # Hash can change, and is preserved across invocations.
            new_conn = connect_to_gcp
            { connection: new_conn }
          end
        end

        def name
          'gcp'
        end

        # main configuration options
        def project
          dns_config['project']
        end

        def zone_name
          dns_config['zone_name']
        end

        # Cloud DNS applies the changes to a zone one at a time, and vmpooler runs several managers and many
        # clones at once, so a change can lose a race. These errors mean "someone else changed the zone, or
        # this record, a moment ago", and trying the change again from a fresh read settles them:
        #   AlreadyExistsError      the record appeared after we looked, or an earlier try of this very change
        #                           was applied although we never saw the answer
        #   FailedPreconditionError a change that depends on state another change just replaced
        RETRYABLE_ERRORS = [Google::Cloud::AlreadyExistsError, Google::Cloud::FailedPreconditionError].freeze
        MAX_ATTEMPTS = 5
        RETRY_DELAY_SECONDS = 1

        # Make hostname resolve to the VM's IP address, whether or not a record for it exists already.
        #
        # One change replaces whatever A record the name has with the new one (a plain add when there is none),
        # and does nothing when the record is already right. It is retried as a whole, reading the zone again,
        # so a race with another change cannot raise from inside an error handler, which is how the earlier
        # add-then-replace version let AlreadyExistsError and FailedPreconditionError escape and fail the clone
        # (P4DEVOPS-16408).
        #
        # skip_soa: the client library otherwise adds a delete of the zone's SOA record and an add of the next
        # serial to every change. That read-modify-write of one shared record is what makes concurrent changes
        # fail their precondition. Cloud DNS raises the serial itself.
        #
        # Raises the last error when the change still fails after MAX_ATTEMPTS, so the clone fails visibly
        # instead of leaving a VM without a record.
        def create_or_replace_record(hostname)
          ip = get_ip(hostname)
          if ip.nil?
            debug_logger("An IP Address was not recorded for #{hostname}")
            return
          end

          with_dns_retries("create_or_replace_record #{hostname}") do
            change = connection.zone(zone_name).replace(hostname, 'A', 60, ip, skip_soa: true)
            debug_logger("#{change.id} - #{change.started_at} - #{change.status} DNS address set") if change
          end
        end

        # Remove the A record for hostname. Nothing to do when there is none. A change that keeps failing is
        # logged and given up on, not raised: the VM is already gone and a leftover record is harmless, where
        # raising would make vmpooler treat the destroy as failed.
        def delete_record(hostname)
          with_dns_retries("delete_record #{hostname}") do
            connection.zone(zone_name).remove(hostname, 'A', skip_soa: true)
          end
        rescue *RETRYABLE_ERRORS => e
          debug_logger("GCP DNS delete_record #{hostname} gave up after #{MAX_ATTEMPTS} attempts: #{e.class}: #{e.message}", send_to_upstream: true)
          metrics.increment('dns.gcp.delete_gave_up')
          nil
        end

        def connection
          @connection_pool.with_metrics do |pool_object|
            return ensured_gcp_connection(pool_object)
          end
        end

        def ensured_gcp_connection(connection_pool_object)
          connection_pool_object[:connection] = connect_to_gcp unless gcp_connection_ok?(connection_pool_object[:connection])
          connection_pool_object[:connection]
        end

        def gcp_connection_ok?(connection)
          _result = connection.id
          true
        rescue StandardError
          false
        end

        def connect_to_gcp
          max_tries = global_config[:config]['max_tries'] || 3
          retry_factor = global_config[:config]['retry_factor'] || 10
          try = 1
          begin
            Google::Cloud::Dns.configure do |config|
              config.project_id = project
            end

            dns = Google::Cloud::Dns.new

            metrics.increment('connect.open')
            dns
          rescue StandardError => e
            metrics.increment('connect.fail')
            raise e if try >= max_tries

            sleep(try * retry_factor)
            try += 1
            retry
          end
        end

        # Run the block, and run it again from the start while it fails with one of RETRYABLE_ERRORS, up to
        # MAX_ATTEMPTS times in all. The wait grows with each attempt and has some randomness, so managers
        # that collided do not collide again. Every retry is logged upstream and counted, so it can be seen.
        def with_dns_retries(operation)
          attempt = 0
          begin
            attempt += 1
            yield
          rescue *RETRYABLE_ERRORS => e
            raise if attempt >= MAX_ATTEMPTS

            metrics.increment('dns.gcp.retry')
            debug_logger("#{operation}: #{e.class}, attempt #{attempt} of #{MAX_ATTEMPTS}, trying again", send_to_upstream: true)
            sleep(attempt * RETRY_DELAY_SECONDS + rand)
            retry
          end
        end

        # used in local dev environment, set DEBUG_FLAG=true
        # this way the upstream vmpooler manager does not get polluted with logs
        def debug_logger(message, send_to_upstream: false)
          # the default logger is simple and does not enforce debug levels (the first argument)
          puts message if ENV['DEBUG_FLAG']
          logger.log('[g]', message) if send_to_upstream
        end
      end
    end
  end
end
