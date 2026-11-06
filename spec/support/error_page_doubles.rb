# frozen_string_literal: true

# Doubles for an ErrorPage and its parts, so the rendering specs can build a page without raising a
# real exception or making a real request.
module ErrorPageDoubles
  def xss
    "<script>alert(1)</script>"
  end

  def variable(name, class_name, value)
    Hanami::Webconsole::Variable.new(name:, class_name:, value:)
  end

  def excerpt(lines, first_lineno: 10, highlight_lineno: 11)
    Hanami::Webconsole::SourceFile::Excerpt.new(
      path: "/app/lib/bookshelf/repositories/book_repo.rb",
      first_lineno:,
      lines:,
      highlight_lineno:
    )
  end

  def frame(
    kind: :app,
    path: "/app/lib/bookshelf/repositories/book_repo.rb",
    display_path: "lib/bookshelf/repositories/book_repo.rb",
    lineno: 11,
    label: "Bookshelf::Repositories::BookRepo#find",
    source: excerpt(["def find(id)", "  books.by_pk(id).one!", "end"]),
    locals: [variable("id", "Integer", "247")],
    instance_vars: [],
    frame_binding: nil,
    file: true
  )
    instance_double(
      Hanami::Webconsole::Frame,
      kind:,
      app?: kind == :app,
      file?: file,
      path:,
      display_path:,
      lineno:,
      label:,
      source:,
      locals:,
      instance_vars:,
      binding: frame_binding
    )
  end

  def request_context(
    method_name: "GET",
    params: {"id" => "247"},
    session: {},
    cookies: {},
    headers: {"User-Agent" => "Mozilla/5.0"}
  )
    instance_double(
      Hanami::Webconsole::RequestContext,
      method_name:,
      path: "/books/247",
      format: "text/html",
      ip: "127.0.0.1",
      params:,
      session:,
      cookies:,
      headers:
    )
  end

  def error_page(
    exception_class: "NoMethodError",
    message: "undefined method 'titel' for an instance of Book",
    detailed_extras: [],
    status: 500,
    causes: [],
    frames: [frame],
    request: request_context,
    diagnostic: nil
  )
    instance_double(
      Hanami::Webconsole::ErrorPage,
      id: "a1b2c3",
      exception_class:,
      message:,
      detailed_extras:,
      status:,
      actionable?: !diagnostic&.fix.nil?,
      diagnostic:,
      causes:,
      frames:,
      app_frames: frames.select(&:app?),
      request:
    )
  end

  # A real wrapped diagnostic, around one that returns the given parts.
  def diagnostic(**parts)
    source = Class.new {
      parts.each { |name, value| define_method(name) { value } }
    }.new

    Hanami::Diagnostics::Wrapper.new(source)
  end
end
