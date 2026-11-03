# frozen_string_literal: true

require "json"

module Hanami
  module Webconsole
    module Rendering
      # Renders an {ErrorPage} as JSON, for the `application/json` response.
      #
      # @api private
      class JSON
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

        private

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
