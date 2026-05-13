require_relative "boot"
require "action_cable/engine"
require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module RecontrolBackend
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Phase 18: app/ai_tools/ is namespaced under the AiTools module rather
    # than treated as an autoload root. Zeitwerk normally infers
    # app/ai_tools/base.rb -> top-level Base; we want AiTools::Base. Remove
    # the directory from the default-pushed roots and re-attach it as a
    # namespaced dir before Zeitwerk's setup runs.
    ai_tools_path = Rails.root.join("app/ai_tools").to_s
    config.autoload_paths     -= [ai_tools_path]
    config.eager_load_paths   -= [ai_tools_path]

    initializer "ai_tools.namespace", before: :setup_main_autoloader do
      # Phase 18: AiTools is a top-level namespace whose body lives in
      # app/ai_tools/base.rb (umbrella REGISTRY + register/fetch/all_definitions
      # + Base abstract class). Zeitwerk normally wants app/ai_tools/base.rb
      # to define top-level Base; we re-attach the directory as a namespaced
      # autoload root so the file's `module AiTools; class Base; ...` is the
      # canonical mapping target.
      module ::AiTools; end
      Rails.autoloaders.main.push_dir(
        Rails.root.join("app/ai_tools"),
        namespace: ::AiTools
      )
    end

    # Phase 18: eager-load every concrete tool at boot so AiTools::REGISTRY is
    # populated before AgentRunner's first AiTools.fetch / .all_definitions
    # call. Rails' default eager_load is false in dev/test, so without this
    # the four tools only register lazily on first const reference -- which
    # would break `AiTools.fetch("run_command")` from a fresh runner.
    config.after_initialize do
      next unless defined?(::AiTools)
      Dir.glob(Rails.root.join("app/ai_tools/*.rb")).sort.each do |path|
        const_name = File.basename(path, ".rb").camelize
        next if const_name == "Base"
        ::AiTools.const_get(const_name)
      end

      # Phase 19: warn (do not fail) if any allow-listed binary is missing on
      # the host running the Rails server. This is a forensics aid; the policy
      # itself fails closed at request time regardless.
      ::CommandPolicy.warn_missing_paths! if defined?(::CommandPolicy)
    end

    # Dev-only hot-reload support for app/ai_tools/. Zeitwerk reloads the
    # subclass files on edit, but stale class references stay cached in
    # AiTools::REGISTRY because the registry is populated only at boot via
    # the after_initialize block above. `to_prepare` fires on every Rails
    # reload in dev: we clear the registry and re-resolve each tool through
    # the live autoloader so AiTools.fetch returns the freshly-loaded class.
    # First-boot guard: REGISTRY isn't defined yet on the very first prepare
    # callback (it's defined when AiTools::Base autoloads); skip until then.
    Rails.application.config.to_prepare do
      next unless defined?(::AiTools::REGISTRY)
      ::AiTools::REGISTRY.clear
      Dir.glob(Rails.root.join("app/ai_tools/*.rb")).sort.each do |path|
        const_name = File.basename(path, ".rb").camelize
        next if const_name == "Base"
        ::AiTools.const_get(const_name)
      end
    end

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true
    config.middleware.use ActionDispatch::Cookies
    config.generators do |g|
      g.orm :active_record, primary_key_type: :uuid
    end

    config.hosts << "dev3000.kokhan.me"
    config.hosts << "port3003.kokhan.me"
  end
end
