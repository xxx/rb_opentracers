class RbOpentracers::Span < OpenTracing::Span
  attr_accessor :operation_name, :tags, :start_time
  attr_reader :span_context

  # Creates a new {Span}
  #
  # @param tracer [Tracer] the tracer that created this span
  # @param span_context [SpanContext] the context of the span
  # @return [Span] a new Span
  def initialize(tracer, span_context)
    @tracer = tracer
    @span_context = span_context
    @tags = {}
    @log_entries = []
  end

  # Set a tag value on this span
  # @param key [String] the key of the tag
  # @param value [String, Numeric, Boolean] the value of the tag. If it's not
  # a String, Numeric, or Boolean it will be encoded with to_s
  def set_tag(key, value)
    unless value.is_a?(String) || value.is_a?(Numeric) || !!value == value
      value = value.to_s
    end
    @tags[key] = value
  end

  # Set a baggage item on the span
  # @param key [String] the key of the baggage item
  # @param value [String] the value of the baggage item
  def set_baggage_item(key, value)
    span_context.set_baggage_item(key, value)
  end

  # Get a baggage item
  # @param key [String] the key of the baggage item
  # @return Value of the baggage item
  def get_baggage_item(key)
    span_context.get_baggage_item(key)
  end

  # Add a log entry to this span
  # @param event [String] event name for the log
  # @param timestamp [Time] time of the log
  # @param fields [Hash] Additional information to log
  def log(event: nil, timestamp: Time.now, fields: nil)
    entry = {
      event: event,
      timestamp: timestamp,
    }

    entry[:fields] = fields if fields
    @log_entries << entry

    nil
  end

  # Finish the {Span}
  # @param end_time [Time] custom end time, if not now
  def finish(end_time: Time.now)
    if @tracer.sample_test.call(@span_context.trace_id)
      @tracer.reporter.register(
        operation_name: @operation_name,
        start_time: @start_time,
        end_time: end_time,
        span_context: @span_context,
        tags: @tags,
        log_entries: @log_entries
      )
    end
  end

  # https://github.com/opentracing/specification/blob/master/semantic_conventions.md
  TAG_COMPONENT = 'component'
  TAG_DB_INSTANCE = 'db.instance'
  TAG_DB_STATEMENT = 'db.statement'
  TAG_DB_TYPE = 'db.type'
  TAG_DB_USER = 'db.user'
  TAG_ERROR = 'error'
  TAG_HTTP_METHOD = 'http.method'
  TAG_HTTP_STATUS_CODE = 'http.status_code'
  TAG_HTTP_URL = 'http.url'
  TAG_MB_DESTINATION = 'message_bus.destination'
  TAG_PEER_HOSTNAME = 'peer.hostname'
  TAG_PEER_IPV4 = 'peer.ipv4'
  TAG_PEER_IPV6 = 'peer.ipv6'
  TAG_PEER_PORT = 'peer.port'
  TAG_PEER_SERVICE = 'peer.service'
  TAG_SAMPLING_PRIORITY = 'sampling.priority'
  TAG_SPAN_KIND = 'span.kind'

  LOG_ERROR_KIND = 'error.kind'
  LOG_ERROR_OBJECT = 'error.object'
  LOG_EVENT = 'event'
  LOG_MESSAGE = 'message'
  LOG_STACK = 'stack'
end
