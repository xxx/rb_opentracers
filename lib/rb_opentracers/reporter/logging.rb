class RbOpentracers::Reporter::Logging
  attr_accessor :logger, :log_level

  def initialize(logger: Logger.new($stdout), log_level: :debug)
    @logger = logger
    @log_level = log_level
  end

  def start
    # no-op. Here for Recorder API conformance
  end

  def register(event)
    @logger.send(@log_level, event)
  end
end
