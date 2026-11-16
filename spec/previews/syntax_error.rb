# frozen_string_literal: true

# A syntax error, as when Zeitwerk loads a broken file. Ruby's message quotes the source with a
# caret under the problem, so it only reads right if every character stays in its column.
Previews.scenario "syntax_error", "Syntax error, with a caret under the source" do
  source = "def call(request, response\n  response.body = \"ok\"\nend\n"
  eval(source, binding, "app/actions/books/show.rb", 3) # rubocop:disable Security/Eval
end
