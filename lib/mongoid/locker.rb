require File.expand_path(File.join(File.dirname(__FILE__), 'locker', 'version'))
require File.expand_path(File.join(File.dirname(__FILE__), 'locker', 'wrapper'))

module Mongoid
  module Locker
    # Error thrown if document could not be successfully locked.
    class LockError < Exception; end

    module ClassMethods
      # A scope to retrieve all locked documents in the collection.
      #
      # @return [Mongoid::Criteria]
      def locked
        where :mongoid_locker_locked_until.gt => Time.now
      end

      # A scope to retrieve all unlocked documents in the collection.
      #
      # @return [Mongoid::Criteria]
      def unlocked
        any_of({ mongoid_locker_locked_until: nil }, { :mongoid_locker_locked_until.lte => Time.now })
      end

      # Set the default lock timeout for this class.  Note this only applies to new locks.  Defaults to five seconds.
      #
      # @param [Fixnum] new_time the default number of seconds until a lock is considered "expired", in seconds
      # @return [void]
      def timeout_lock_after(new_time)
        @lock_timeout = new_time
      end

      # Retrieve the lock timeout default for this class.
      #
      # @return [Fixnum] the default number of seconds until a lock is considered "expired", in seconds
      def lock_timeout
        # default timeout of five seconds
        @lock_timeout || 5
      end
    end

    # @api private
    def self.included(mod)
      mod.extend ClassMethods

      mod.field :mongoid_locker_locked_at, type: Time
      mod.field :mongoid_locker_locked_until, type: Time
    end

    # Returns whether the document is currently locked or not.
    #
    # @return [Boolean] true if locked, false otherwise
    def locked?
      !!(mongoid_locker_locked_until && mongoid_locker_locked_until > Time.now)
    end

    # Returns whether the current instance has the lock or not.
    #
    # @return [Boolean] true if locked, false otherwise
    def has_lock?
      !!(@has_lock && self.locked?)
    end

    # Primary method of plugin: execute the provided code once the document has been successfully locked.
    #
    # @param [Hash] opts for the locking mechanism
    # @option opts [Fixnum] :timeout The number of seconds until the lock is considered "expired" - defaults to the {ClassMethods#lock_timeout}
    # @option opts [Fixnum] :retries If the document is currently locked, the number of times to retry. Defaults to 0 (note: setting this to 1 is the equivalent of using :wait => true)
    # @option opts [Float] :retry_sleep How long to sleep between attempts to acquire lock - defaults to time left until lock is available
    # @option opts [Boolean] :wait If the document is currently locked, wait until the lock expires and try again - defaults to false. If set, :retries will be ignored
    # @option opts [Boolean] :reload After acquiring the lock, reload the document - defaults to true
    # @return [void]
    def with_lock(opts = {})
      had_lock = self.has_lock?

      unless had_lock
        opts[:retries] = 1 if opts[:wait]
        lock(opts)
      end

      begin
        yield
      ensure
        unlock if locked? && !had_lock
      end
    end

    protected

    def acquire_lock(opts = {})
      time = Time.now
      timeout = opts[:timeout] || self.class.lock_timeout
      expiration = time + timeout

      # lock the document atomically in the DB without persisting entire doc
      locked = Mongoid::Locker::Wrapper.update(
        self.class,
        {
          :_id => id,
          '$or' => [
            # not locked
            { mongoid_locker_locked_until: nil },
            # expired
            { mongoid_locker_locked_until: { '$lte' => time } }
          ]
        },

        '$set' => {
          mongoid_locker_locked_at:    time,
          mongoid_locker_locked_until: expiration
        }

      )

      if locked
        # document successfully updated, meaning it was locked
        self.mongoid_locker_locked_at = time
        self.mongoid_locker_locked_until = expiration
        reload unless opts[:reload] == false
        @has_lock = true
      else
        @has_lock = false
      end
    end

    def lock(opts = {})
      opts = { retries: 0 }.merge(opts)

      attempts_left = opts[:retries] + 1
      retry_sleep = opts[:retry_sleep]

      loop do
        return if acquire_lock(opts)

        attempts_left -= 1

        if attempts_left > 0
          # if not passed a retry_sleep value, we sleep for the remaining life of the lock
          unless opts[:retry_sleep]
            locked_until = Mongoid::Locker::Wrapper.locked_until(self)
            # the lock might be released since the last check so make another attempt
            next unless locked_until
            retry_sleep = locked_until - Time.now
          end

          sleep retry_sleep if retry_sleep > 0
        else
          fail LockError.new('could not get lock')
        end
      end
    end

    def unlock
      # unlock the document in the DB without persisting entire doc
      Mongoid::Locker::Wrapper.update(
        self.class,
        { _id: id },

        '$set' => {
          mongoid_locker_locked_at:    nil,
          mongoid_locker_locked_until: nil,
        }

      )
      
      unless destroyed?
        self.mongoid_locker_locked_at = nil
        self.mongoid_locker_locked_until = nil
      end
      @has_lock = false
    end
  end
end
