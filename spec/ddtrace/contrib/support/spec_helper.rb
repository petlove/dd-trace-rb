require 'spec_helper'

RSpec.configure do |config|
  # Raise error when patching an integration fails.
  # This can be disabled by unstubbing +CommonMethods#on_patch_error+
  require 'ddtrace/contrib/patcher'
  config.before(:each) do
    allow_any_instance_of(Datadog::Contrib::Patcher::CommonMethods).to(receive(:on_patch_error)) { |_, e| raise e }
  end

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
    allow_any_instance_of(Datadog::Tracer).to receive(:write) do |tracer, trace|
      tracer.instance_exec do
        @spans ||= []
        @spans << trace
      end
    end

    # allow(Datadog::Configuration::Components).to receive(:build_tracer).and_wrap_original do |original_method, settings|
    #   if @tracer
    #     # We monitor and raise errors on all methods calls to stale tracer instances.
    #     # We allow #shutdown! to be called though, as finalizing a stale instance is allowed.
    #     methods = (Datadog::Tracer.instance_methods - Object.instance_methods) - [:shutdown!]
    #     methods.each do |method|
    #       allow(@tracer).to receive(method).and_raise(
    #         "Stale tracer instance: superseded during reconfiguration at #{caller.drop(2).join("\n")}"
    #       )
    #     end
    #   end
    #
    #   @tracer = if defined?(@use_real_tracer) && @use_real_tracer
    #               original_method.call(settings)
    #             else
    #               get_test_tracer(default_service: settings.service,
    #                               enabled: settings.tracer.enabled,
    #                               partial_flush: settings.tracer.partial_flush.enabled,
    #                               tags: settings.tags.dup.tap do |tags|
    #                                 tags['env'] = settings.env unless settings.env.nil?
    #                                 tags['version'] = settings.version unless settings.version.nil?
    #                               end)
    #             end
    # end
  end

  def use_real_tracer!
    allow_any_instance_of(Datadog::Tracer).to receive(:write).and_call_original
  end
end
