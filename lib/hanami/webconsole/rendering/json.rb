# frozen_string_literal: true

require "json"

require_relative "../safety"

module Hanami
  module Webconsole
    module Rendering
      # Renders an {ErrorPage} as JSON, for the `application/json` response.
      #
      # Like the other renderings, this must never raise. If the error can't be read, it falls back
      # to just the exception's class name, so a client that asked for JSON still gets JSON.
      #
      # @api private
      class JSON
        include Safety

        # @return [ErrorPage]
        attr_reader :page

        # @param page [ErrorPage]
        def initialize(page)
          @page = page
        end

        # Returns the error as JSON.
        #
        # @return [String]
        def to_s
          safely(fallback) { document }
        end

        private

        def document
          ::JSON.generate(
            "error" => page.exception_class,
            "message" => page.message,
            "status" => page.status,
            "actionable" => page.actionable?,
            "diagnostic" => diagnostic_json,
            "causes" => page.causes,
            "backtrace" => backtrace_json,
            "request" => request_json
          )
        end

        # The output when nothing else can be rendered: just the exception's class name.
        def fallback
          ::JSON.generate("error" => safely("Exception") { page.exception_class })
        end

        def diagnostic_json
          diagnostic = page.diagnostic
          return nil unless diagnostic

          fix = diagnostic.fix
          dataset = diagnostic.dataset

          {
            "title" => diagnostic.title,
            "explanation" => diagnostic.explanation,
            "fix" => fix && {
              "name" => fix.name,
              "text" => fix.text,
              "runnable" => diagnostic.runnable_fix?,
              "destructive" => fix.destructive
            },
            "dataset" => dataset && {"title" => dataset.title, "columns" => dataset.columns, "rows" => dataset.rows}
          }
        end

        def backtrace_json
          page.frames.map { |frame| "#{frame.path}:#{frame.lineno}:in '#{frame.label}'" }
        end

        def request_json
          request = page.request

          {
            "method" => request.method_name,
            "path" => request.path,
            "format" => request.format,
            "ip" => request.ip,
            "params" => request.params
          }
        end
      end
    end
  end
end
