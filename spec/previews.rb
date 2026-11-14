# frozen_string_literal: true

require "fileutils"
require "stringio"
require "hanami/webconsole"

# A gallery of error pages, for checking the page's layout against a range of real errors.
#
# Each scenario raises a real exception and renders it with the real renderer, so the page goes
# through everything a live request would: `detailed_message` extras, backtrace parsing, diagnostics
# and causes. Only the console needs a server, so it won't evaluate here.
#
#   bundle exec rake preview   # writes tmp/previews/, open index.html
#
# Scenarios are in `spec/previews/`, one per file. They live outside `spec/support/` so that normal
# spec runs don't load them.
module Previews
  ROOT = File.expand_path("..", __dir__)

  # Frames under this directory count as app frames, so the scenarios' own code looks like the app.
  Config = Struct.new(:root, :render_error_responses, :logger)

  Scenario = Struct.new(:name, :description, :env, :block) do
    def page
      @page ||= Hanami::Webconsole::ErrorPage.new(
        exception:,
        env: Previews.env(**env),
        config: Config.new(root: File.join(ROOT, "spec/previews"), render_error_responses: {}),
        bindings: bindings
      )
    end

    def exception
      @exception ||= begin
        result = block.call
        # A scenario can return an exception it never raised, for the no-backtrace state.
        raise "Scenario #{name} didn't raise" unless result.is_a?(Exception)

        result
      rescue Exception => exception # rubocop:disable Lint/RescueException
        exception
      end
    end

    private

    def bindings
      return unless exception.respond_to?(:__hanami_webconsole_bindings)

      found = exception.__hanami_webconsole_bindings
      found.empty? ? nil : found
    end
  end

  class << self
    def scenarios
      load_scenarios
      registered.values
    end

    def find(name)
      scenarios.find { |scenario| scenario.name == name } or raise KeyError, "No preview named #{name}"
    end

    # Defines a scenario. The block raises the exception to show.
    def scenario(name, description, **env, &block)
      registered[name] = Scenario.new(name, description, env, block)
    end

    def render(scenario)
      Hanami::Webconsole::Rendering::HTML.new(scenario.page, nonce: "preview").to_s
    end

    # Writes each scenario to `<dir>/<name>.html`, with an index linking them all.
    def write(dir)
      FileUtils.mkdir_p(dir)

      scenarios.each do |scenario|
        File.write(File.join(dir, "#{scenario.name}.html"), render(scenario))
      end

      File.write(File.join(dir, "index.html"), index_html)
    end

    # A Rack env for a request to the app. Options override the defaults.
    def env(method: "GET", path: "/books/247", headers: {}, cookies: {}, session: {}, params: {})
      query = params.map { |key, value| "#{key}=#{value}" }.join("&")
      cookie = cookies.map { |key, value| "#{key}=#{value}" }.join("; ")

      {
        "REQUEST_METHOD" => method,
        "PATH_INFO" => path,
        "QUERY_STRING" => query,
        "SERVER_NAME" => "localhost",
        "SERVER_PORT" => "2300",
        "REMOTE_ADDR" => "127.0.0.1",
        "rack.url_scheme" => "http",
        "rack.input" => StringIO.new,
        "rack.session" => session,
        "HTTP_HOST" => "localhost:2300",
        "HTTP_ACCEPT" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "HTTP_ACCEPT_ENCODING" => "gzip, deflate, br, zstd",
        "HTTP_ACCEPT_LANGUAGE" => "en-AU,en;q=0.9",
        "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15",
        "HTTP_COOKIE" => cookie
      }.merge(headers.to_h { |name, value| ["HTTP_#{name.upcase.tr("-", "_")}", value] })
    end

    private

    def registered
      @registered ||= {}
    end

    def load_scenarios
      return if @loaded

      Dir[File.join(ROOT, "spec/previews/*.rb")].sort.each { |file| require file }
      @loaded = true
    end

    def index_html
      items = scenarios.map { |scenario|
        %(<li><a href="#{scenario.name}.html">#{scenario.name}</a> &ndash; #{escape(scenario.description)}</li>)
      }

      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Webconsole previews</title>
        <style>body { font: 15px/1.6 system-ui; max-width: 48rem; margin: 3rem auto; } a { font-family: ui-monospace, monospace; }</style>
        </head>
        <body>
        <h1>Webconsole previews</h1>
        <ul>
        #{items.join("\n")}
        </ul>
        </body>
        </html>
      HTML
    end

    def escape(text)
      Rack::Utils.escape_html(text)
    end
  end
end
