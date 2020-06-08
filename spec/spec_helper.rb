$LOAD_PATH.unshift File.expand_path('../../', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'pry'
require 'rspec/collection_matchers'
require 'webmock/rspec'
require 'climate_control'

require 'ddtrace/encoding'
require 'ddtrace/tracer'
require 'ddtrace/span'

require 'support/configuration_helpers'
require 'support/container_helpers'
require 'support/faux_transport'
require 'support/faux_writer'
require 'support/health_metric_helpers'
require 'support/http_helpers'
require 'support/log_helpers'
require 'support/metric_helpers'
require 'support/network_helpers'
require 'support/platform_helpers'
require 'support/span_helpers'
require 'support/spy_transport'
require 'support/synchronization_helpers'
require 'support/tracer_helpers'

begin
  # Ignore interpreter warnings from external libraries
  require 'warning'

  # Suppress gem warnings
  Warning.ignore([:method_redefined, :not_reached, :unused_var, :safe, :taint, :missing_ivar], %r{.*/gems/[^/]*/lib/})

  # Suppress internal warnings
  Warning.ignore([:missing_ivar])
rescue LoadError
  puts 'warning suppressing gem not available, external library warnings will be displayed'
end

WebMock.allow_net_connect!
WebMock.disable!

METHODS = (Datadog::Tracer.instance_methods - Object.instance_methods) - [:shutdown!]

module TestConfig
  module_function

  def raise_on_patch_error?
    true
  end
end

RSpec.configure do |config|
  config.before(:each) do
    allow_any_instance_of(Datadog::Pin)
      .to receive(:deprecation_warning)
            .and_raise('Tracer cannot be eagerly cached. In production this is just a warning.')

    require 'rspec/mocks/test_double'
    allow_any_instance_of(Datadog::Configuration::Option)
      .to receive(:set).and_wrap_original do |original_method, value|

      option = original_method.receiver

      if !(option.definition.class < RSpec::Mocks::TestDouble) && option.definition.name == :tracer && !(value.class < Datadog::Configuration::Base) && !value.instance_variable_get(:@dd_use_real_tracer)
        raise 'Eagerly setting tracer is not allowed'
      end

      original_method.call(value)
    end

    require 'ddtrace/contrib/patcher'
    allow_any_instance_of(Datadog::Contrib::Patcher::CommonMethods).to(receive(:on_patch_error)) { |_, e| raise e }
  end


  config.before(:each) do
    allow(Datadog::Configuration::Components).to receive(:build_tracer) do |settings|
      if @tracer
        METHODS.each do |method|
          allow(@tracer).to receive(method).and_raise("wrong tracer")
        end
      end

      @tracer = get_test_tracer(default_service: settings.service,
                                enabled: settings.tracer.enabled,
                                partial_flush: settings.tracer.partial_flush.enabled,
                                tags: settings.tags.dup.tap do |tags|
                                  tags['env'] = settings.env unless settings.env.nil?
                                  tags['version'] = settings.version unless settings.version.nil?
                                end
      )
    end
  end

  config.include ConfigurationHelpers
  config.include ContainerHelpers
  config.include HealthMetricHelpers
  config.include HttpHelpers
  config.include LogHelpers
  config.include MetricHelpers
  config.include NetworkHelpers
  config.include SpanHelpers
  config.include SynchronizationHelpers
  config.include TracerHelpers

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.warnings = true
  config.order = :random

  config.after(:each) do
    Datadog.shutdown!
    Datadog.configuration.reset!
  end
end
