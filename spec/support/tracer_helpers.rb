require 'ddtrace/tracer'
require 'ddtrace/span'
require 'support/faux_writer'

# rubocop:disable Metrics/ModuleLength
module TracerHelpers
  # Returns the current tracer instance
  def tracer
    @tracer || instance_double(Datadog::Tracer, 'Bad tracer instance: created before Datadog.configure')
  end

  def new_tracer(options = {})
    writer = FauxWriter.new(
      transport: Datadog::Transport::HTTP.default do |t|
        t.adapter :test
      end
    )

    options = { writer: writer }.merge(options)
    Datadog::Tracer.new(options).tap do |tracer|
      # TODO: Let's try to get rid of this override, which has too much
      #       knowledge about the internal workings of the tracer.
      #       It is done to prevent the activation of priority sampling
      #       from wiping out the configured test writer, by replacing it.
      tracer.define_singleton_method(:configure) do |opts = {}|
        super(opts)

        # Re-configure the tracer with a new test writer
        # since priority sampling will wipe out the old test writer.
        unless @writer.is_a?(FauxWriter)
          @writer = if @sampler.is_a?(Datadog::PrioritySampler)
                      FauxWriter.new(
                        priority_sampler: @sampler,
                        transport: Datadog::Transport::HTTP.default do |t|
                          t.adapter :test
                        end
                      )
                    else
                      FauxWriter.new(
                        transport: Datadog::Transport::HTTP.default do |t|
                          t.adapter :test
                        end
                      )
                    end

          statsd = opts.fetch(:statsd, nil)
          @writer.runtime_metrics.statsd = statsd unless statsd.nil?
        end
      end
    end
  end

  # TODO: Replace references to `get_test_tracer` with `tracer`.
  # TODO: Use `new_tracer` instead if custom options are provided.
  alias get_test_tracer new_tracer

  # Return a test tracer instance with a faux writer.
  def get_test_tracer_with_old_transport(options = {})
    options = { writer: FauxWriter.new }.merge(options)
    Datadog::Tracer.new(options).tap do |tracer|
      # TODO: Let's try to get rid of this override, which has too much
      #       knowledge about the internal workings of the tracer.
      #       It is done to prevent the activation of priority sampling
      #       from wiping out the configured test writer, by replacing it.
      tracer.define_singleton_method(:configure) do |opts = {}|
        super(opts)

        # Re-configure the tracer with a new test writer
        # since priority sampling will wipe out the old test writer.
        unless @writer.is_a?(FauxWriter)
          @writer = if @sampler.is_a?(Datadog::PrioritySampler)
                      FauxWriter.new(priority_sampler: @sampler)
                    else
                      FauxWriter.new
                    end

          hostname = opts.fetch(:hostname, nil)
          port = opts.fetch(:port, nil)

          @writer.transport.hostname = hostname unless hostname.nil?
          @writer.transport.port = port unless port.nil?

          statsd = opts.fetch(:statsd, nil)
          unless statsd.nil?
            @writer.statsd = statsd
            @writer.transport.statsd = statsd
          end
        end
      end
    end
  end

  def get_test_writer(options = {})
    options = {
      transport: Datadog::Transport::HTTP.default do |t|
        t.adapter :test
      end
    }.merge(options)

    FauxWriter.new(options)
  end

  # Return some test traces
  def get_test_traces(n)
    traces = []

    defaults = {
      service: 'test-app',
      resource: '/traces',
      span_type: 'web'
    }

    n.times do
      span1 = Datadog::Span.new(nil, 'client.testing', defaults).finish()
      span2 = Datadog::Span.new(nil, 'client.testing', defaults).finish()
      span2.set_parent(span1)
      traces << [span1, span2]
    end

    traces
  end

  # Return some test services
  def get_test_services
    { 'rest-api' => { 'app' => 'rails', 'app_type' => 'web' },
      'master' => { 'app' => 'postgres', 'app_type' => 'db' } }
  end

  def writer
    tracer.writer
  end

  def spans
    @spans ||= writer.spans
  end

  # Returns the only span in the current tracer writer.
  #
  # This method will not allow for ambiguous use,
  # meaning it will throw an error when more than
  # one span is available.
  def span
    @span ||= begin
                expect(spans).to have(1).item, "Requested the only span, but #{spans.size} spans are available"
                spans.first
              end
  end

  def clear_spans
    writer.spans(:clear)

    @spans = nil
    @span = nil
  end

  def self.included(config)
    # Ensure tracer environment is clean before running test
    #
    # This is done :before and not :after because doing so after
    # can create noise for test assertions. For example:
    # +expect(Datadog).to receive(:shutdown!).once+
    config.before(:each) do
      Datadog.shutdown!
      Datadog.configuration.reset!
    end

    # Ensure only the most recent tracer instance (found under +Datadog.tracer+) is actively used.
    # Trying to perform operations on a stale tracer will raise errors during a test run.
    config.before(:each) do
      allow(Datadog::Configuration::Components).to receive(:build_tracer).and_wrap_original do |original_method, settings|
        if @tracer
          # We monitor and raise errors on all methods calls to stale tracer instances.
          # We allow #shutdown! to be called though, as finalizing a stale instance is allowed.
          methods = (Datadog::Tracer.instance_methods - Object.instance_methods) - [:shutdown!]
          methods.each do |method|
            allow(@tracer).to receive(method).and_raise(
              "Stale tracer instance: superseded during reconfiguration at #{caller.drop(2).join("\n")}"
            )
          end
        end

        @tracer = if defined?(@use_real_tracer) && @use_real_tracer
                    original_method.call(settings)
                  else
                    get_test_tracer(default_service: settings.service,
                                    enabled: settings.tracer.enabled,
                                    partial_flush: settings.tracer.partial_flush.enabled,
                                    tags: settings.tags.dup.tap do |tags|
                                      tags['env'] = settings.env unless settings.env.nil?
                                      tags['version'] = settings.version unless settings.version.nil?
                                    end)
                  end
      end
    end
  end

  def use_real_tracer!
    @use_real_tracer = true
  end
end
