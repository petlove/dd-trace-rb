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
  end

  def use_real_tracer!
    allow_any_instance_of(Datadog::Tracer).to receive(:write).and_call_original
  end
end
