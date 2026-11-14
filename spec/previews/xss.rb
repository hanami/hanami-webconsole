# frozen_string_literal: true

# Markup in every user-controlled place. None of it should run.
Previews.scenario "xss", "Markup in the message, params, headers and cookies",
  path: "/books/<script>alert(1)</script>",
  headers: {"X-Evil" => "<script>alert(1)</script>"},
  cookies: {"evil" => "<script>alert(1)</script>"},
  session: {"<script>alert(1)</script>" => "<script>alert(1)</script>"},
  params: {"q" => "<script>alert(1)</script>"} do
  raise ArgumentError, "bad title: <script>alert(1)</script>"
end
