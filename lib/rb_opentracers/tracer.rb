class RbOpentracers::Tracer < OpenTracing::Tracer
  # https://github.com/opentracing/specification/blob/master/specification.md

  # TODO(bhs): Support FollowsFrom and multiple references

  attr_reader :reporter, :sample_test

  def initialize(reporter:, sample_test: proc { true })
    @sample_test = sample_test
    @reporter = reporter
    @reporter.start
  end

  # Starts a new span.
  #
  # @param operation_name [String] The operation name for the Span
  # @param child_of [SpanContext] SpanContext that acts as a parent to
  #        the newly-started Span. If a Span instance is provided, its
  #        .span_context is automatically substituted.
  # @param start_time [Time] When the Span started, if not now
  # @param tags [Hash] Tags to assign to the Span at start time
  # @return [Span] The newly-started Span
  def start_span(operation_name, child_of: nil, start_time: Time.now, tags: nil)
    ctx = if child_of.nil?
            ::RbOpentracers::SpanContext.new(trace_id: generate_id)
          else
            parent = child_of.respond_to?(:span_context) ? child_of.span_context : child_of
            ctx_tmp = ::RbOpentracers::SpanContext.new(trace_id: parent.trace_id)
            ctx_tmp.parent_id = parent.id
            ctx_tmp
          end

    span = ::RbOpentracers::Span.new(self, ctx)
    span.operation_name = operation_name
    span.start_time = start_time
    if tags
      tags.each do |k, v|
        span.set_tag(k, v)
      end
    end

    span
  end

  # https://github.com/lightstep/lightstep-tracer-ruby/blob/master/lib/lightstep/tracer.rb

  # Inject a SpanContext into the given carrier
  #
  # @param span_context [SpanContext]
  # @param format [OpenTracing::FORMAT_TEXT_MAP, OpenTracing::FORMAT_BINARY, OpenTracing::FORMAT_RACK]
  # @param carrier [Carrier] A carrier object of the type dictated by the specified `format`
  def inject(span_context, format, carrier)
    case format
      when OpenTracing::FORMAT_TEXT_MAP
        inject_to_text_map(span_context, carrier)
      when OpenTracing::FORMAT_BINARY
        warn 'Binary inject format not yet implemented'
      when OpenTracing::FORMAT_RACK
        inject_to_rack(span_context, carrier)
      else
        warn 'Unknown inject format'
    end
  end

  # Extract a SpanContext in the given format from the given carrier.
  #
  # @param format [OpenTracing::FORMAT_TEXT_MAP, OpenTracing::FORMAT_BINARY, OpenTracing::FORMAT_RACK]
  # @param carrier [Carrier] A carrier object of the type dictated by the specified `format`
  # @return [SpanContext] the extracted SpanContext or nil if none could be found
  def extract(format, carrier)
    case format
      when OpenTracing::FORMAT_TEXT_MAP
        extract_from_text_map(carrier)
      when OpenTracing::FORMAT_BINARY
        warn 'Binary extract format not yet implemented'
        nil
      when OpenTracing::FORMAT_RACK
        extract_from_rack(carrier)
      else
        warn 'Unknown join format'
        nil
    end
  end

  private

  def generate_id
    SecureRandom.random_bytes(16)
  end

  CARRIER_TRACER_STATE_PREFIX = 'ot-tracer-'.freeze
  CARRIER_BAGGAGE_PREFIX = 'ot-baggage-'.freeze

  CARRIER_SPAN_ID = "#{CARRIER_TRACER_STATE_PREFIX}spanid".freeze
  CARRIER_TRACE_ID = "#{CARRIER_TRACER_STATE_PREFIX}traceid".freeze
  CARRIER_SAMPLED = "#{CARRIER_TRACER_STATE_PREFIX}sampled".freeze

  def inject_to_text_map(span_context, carrier)
    carrier[CARRIER_SPAN_ID] = span_context.id
    carrier[CARRIER_TRACE_ID] = span_context.trace_id unless span_context.trace_id.nil?
    carrier[CARRIER_SAMPLED] = 'true'

    span_context.baggage.each do |key, value|
      carrier["#{CARRIER_BAGGAGE_PREFIX}#{key}"] = value
    end
  end

  def extract_from_text_map(carrier)
    # If the carrier does not have both the span_id and trace_id key
    # skip the processing and just return a normal span
    if !carrier.key?(CARRIER_SPAN_ID) || !carrier.key?(CARRIER_TRACE_ID)
      return nil
    end

    baggage = carrier.each_with_object({}) do |tuple, baggage|
      key, value = tuple
      if key.start_with?(CARRIER_BAGGAGE_PREFIX)
        plain_key = key.to_s[CARRIER_BAGGAGE_PREFIX.length..key.to_s.length]
        baggage[plain_key] = value
      end
    end

    SpanContext.new(
      id: carrier[CARRIER_SPAN_ID],
      trace_id: carrier[CARRIER_TRACE_ID],
      baggage: baggage,
    )
  end

  def inject_to_rack(span_context, carrier)
    carrier[CARRIER_SPAN_ID] = span_context.id
    carrier[CARRIER_TRACE_ID] = span_context.trace_id unless span_context.trace_id.nil?
    carrier[CARRIER_SAMPLED] = 'true'

    span_context.baggage.each do |key, value|
      if key =~ /[^\p{L}\p{N}_-]/
        # TODO: log the error internally
        next
      end

      carrier["#{CARRIER_BAGGAGE_PREFIX}#{key}"] = value
    end
  end

  def extract_from_rack(env)
    extract_from_text_map(
      env.each_with_object({}) do |tuple, memo|
        raw_header, value = tuple
        header = raw_header.gsub(/\AHTTP_/, '').tr('_', '-').downcase

        memo[header] = value if header.start_with?(CARRIER_TRACER_STATE_PREFIX, CARRIER_BAGGAGE_PREFIX)
      end
    )
  end
end
