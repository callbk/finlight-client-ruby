# frozen_string_literal: true

# A clock whose time moves only through #advance. Threads sleeping on it wake when their
# deadline is reached (or when someone calls Thread#wakeup on them, like Kernel#sleep).
class FakeClock
  def initialize
    @now = 0.0
    @mutex = Mutex.new
    @sleepers = {}
  end

  def monotonic
    @mutex.synchronize { @now }
  end

  alias now monotonic

  def sleep(seconds)
    if seconds <= 0
      Thread.pass
      return
    end
    @mutex.synchronize do
      @sleepers[Thread.current] = @now + seconds
      @mutex.sleep
    ensure
      @sleepers.delete(Thread.current)
    end
  end

  # Number of threads sleeping on this clock.
  def pending
    @mutex.synchronize { @sleepers.count { |thread, _| thread.alive? } }
  end

  # Earliest deadline of a sleeping thread, or nil.
  def next_deadline
    @mutex.synchronize { @sleepers.select { |t, _| t.alive? }.values.min }
  end

  # Moves time forward, waking every sleeper whose deadline is reached, in order. The optional
  # block runs after every wake-up, to wait for effects that cross threads.
  def advance(seconds, &after_wake)
    target = monotonic + seconds
    loop do
      woken = @mutex.synchronize do
        due = @sleepers.select { |t, deadline| t.alive? && deadline <= target }
        next nil if due.empty?

        thread, deadline = due.min_by { |_, d| d }
        @now = [@now, deadline].max
        @sleepers.delete(thread)
        thread.wakeup
        thread
      end
      break unless woken

      settle(woken)
      after_wake&.call
    end
    @mutex.synchronize { @now = [@now, target].max }
    Kernel.sleep(0.005)
  end

  private

  # Waits until a woken thread blocks again (or ends), so effects happen in time order.
  def settle(thread)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.0
    Kernel.sleep(0.0005)
    while thread.alive? && thread.status == "run" &&
          Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      Kernel.sleep(0.0005)
    end
    Kernel.sleep(0.001)
  end
end
