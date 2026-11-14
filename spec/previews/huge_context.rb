# frozen_string_literal: true

# A request carrying lots of long headers, cookies and session data.
huge_headers = (1..30).to_h { |n| ["X-Custom-Header-#{n}", "value-#{n}-" + ("abc123" * (n % 5 + 1))] }.merge(
  "Authorization" => "Bearer " + ("eyJhbGciOiJIUzI1NiJ9" * 12),
  "Referer" => "http://localhost:2300/books?page=2&sort=title&filter%5Bauthor%5D=" + ("x" * 120)
)

Previews.scenario "huge_context", "Lots of long headers, cookies and session data",
  headers: huge_headers,
  cookies: {
    "ph_phc_E5n5uHnDo2eREJL1uqX1cIlbkoRby4yFWt3V94HqRRg_posthog" =>
      %({"$device_id":"0199a251-440a-7613-a67f-303ea9fdfa15","distinct_id":"928ba#{"0" * 3000}"}),
    "_bookshelf_session" => "a" * 1200,
    "BetterErrors-has-used-console" => "true"
  },
  session: {
    "session_id" => "3312774c9ac944d8f0554fdd53b874d47a0adc3321df430448afd0d92e60d201",
    "_csrf_token" => "ph_phc_E5n5uHnDo2eREJL1uqX1cIlbkoRby4yFWt3V94HqRRg_posthog",
    "user" => {"id" => 1, "roles" => %w[admin editor], "prefs" => {"theme" => "dark", "per_page" => 50}},
    "flash" => {"notice" => "Saved"}
  },
  params: (1..12).to_h { |n| ["field_#{n}", "v#{n}"] } do
  raise KeyError, "key not found: :isbn"
end
