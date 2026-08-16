# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Break Versioning](https://www.taoensso.com/break-versioning).

## [Unreleased]

### Added

- Errors can now say how to fix themselves. An exception that responds to `#resolutions` has its fixes rendered on the error page: a command to copy, a snippet to paste, a list to work through, or a button that runs the fix. There is nothing to include and nothing to inherit, so a gem can offer resolutions without depending on hanami, and an app can define them on its own errors. (@afomera in #15)
- Error pages now show the exception's `#cause` chain, `did_you_mean` suggestions and `error_highlight` carets, none of which better_errors surfaced. (@afomera in #15)
- A "copy as text" button, putting the error, request and backtrace on the clipboard as Markdown. (@afomera in #15)
- The per-frame console now keeps a history, navigable with the up and down arrows. (@afomera in #15)

### Changed

- Replace better_errors with a Hanami-native error page, styled to match `Hanami::Web::Welcome`. The console and its security model carry over unchanged: loopback only, a double-submit CSRF token in an httponly cookie, and a strict Content-Security-Policy with a per-response nonce. (@afomera in #15)
- Status codes now come from `config.render_error_responses` directly, so `Hanami::Router::NotFoundError` renders a 404 without patching `BetterErrors::Middleware#show_error_page`. (@afomera in #15)
- Error pages are held in a bounded registry stamped with a generation counter. More than one error page is interactive at a time, and a page from before a code reload reports an expired session rather than evaluating against unloaded constants. (@afomera in #15)

### Deprecated

### Removed

- The dependency on better_errors. (@afomera in #15)

### Fixed

- binding_of_caller is now probed at load rather than only required. On an engine where it loads but raises when called, the error page degrades to one without local variables or a console, instead of breaking every exception raised in the process. (@afomera in #15)

### Security

[Unreleased]: https://github.com/hanami/hanami-webconsole/compare/v3.0.0...HEAD

## [3.0.0] - 2026-06-30

### Changed

- Update to binding_of_caller 2.0, which formally supports Ruby 4.0. Remove our internal workarounds for this. (@rvmtz in #14)
- Require Ruby 3.3 or newer.

[3.0.0]: https://github.com/hanami/hanami-webconsole/compare/v2.3.3...v3.0.0

## [3.0.0.rc1] - 2026-06-16

### Changed

- Update to binding_of_caller 2.0, which formally supports Ruby 4.0. Remove our internal workarounds for this. (@rvmtz in #14)
- Require Ruby 3.3 or newer.

[3.0.0.rc1]: https://github.com/hanami/hanami-webconsole/compare/v2.3.3...v3.0.0.rc1

## [2.3.1] - 2025-12-18

### Changed

- Bypass binding_of_caller's Ruby version check and load its functionality directly. This ensures it continues to work when running under Ruby 4.0. (@timriley in #12)

[2.3.1]: https://github.com/hanami/hanami-webconsole/compare/v2.3.0...v2.3.1

## [2.3.0] - 2025-11-12

[2.3.0]: https://github.com/hanami/hanami-webconsole/compare/v2.3.0.beta2...v2.3.0

## [2.3.0.beta2] - 2025-10-17

### Changed

- Drop support for Ruby 3.1.

[2.3.0.beta2]: https://github.com/hanami/hanami-webconsole/compare/v2.3.0.beta1...v2.3.0.beta2

## [2.3.0.beta1] - 2025-10-03

[2.3.0.beta1]: https://github.com/hanami/hanami-webconsole/compare/v2.2.0...v2.3.0.beta1

## [2.2.0] - 2024-11-05

[2.2.0]: https://github.com/hanami/hanami-webconsole/compare/v2.2.0.rc1...v2.2.0

## [2.2.0.rc1] - 2024-10-29

[2.2.0.rc1]: https://github.com/hanami/hanami-webconsole/compare/v2.2.0.beta2...v2.2.0.rc1

## [2.2.0.beta2] - 2024-09-25

[2.2.0.beta2]: https://github.com/hanami/hanami-webconsole/compare/v2.2.0.beta1...v2.2.0.beta2

## [2.2.0.beta1] - 2024-07-16

### Changed

- Drop support for Ruby 3.0.

[2.2.0.beta1]: https://github.com/hanami/hanami-webconsole/compare/v2.1.0...v2.2.0.beta1

## [2.1.0] - 2024-02-27

[2.1.0]: https://github.com/hanami/hanami-webconsole/compare/v2.1.0.rc3...v2.1.0

## [2.1.0.rc3] - 2024-02-16

[2.1.0.rc3]: https://github.com/hanami/hanami-webconsole/compare/v2.1.0.rc2...v2.1.0.rc3

## [2.1.0.rc2] - 2023-11-08

[2.1.0.rc2]: https://github.com/hanami/hanami-webconsole/compare/v2.1.0.rc1...v2.1.0.rc2

## [2.1.0.rc1] - 2023-11-02

[2.1.0.rc1]: https://github.com/hanami/hanami-webconsole/compare/v2.1.0.beta2...v2.1.0.rc1

## [2.1.0.beta2] - 2023-10-04

### Fixed

- Set correct error codes for Hanami app exceptions. (@timriley)

[2.1.0.beta2]: https://github.com/hanami/hanami-webconsole/compare/v2.1.0.beta1...v2.1.0.beta2

## [2.1.0.beta1] - 2023-06-29

### Added

- Introduce `Hanami::Webconsole::Middleware`, a Rack middleware automatically used in the Hanami app when hanami-webconsole is bundled. (@timriley in #6)

### Changed

- Remove the Hanami v1 plugin. (@timriley in #6)

[2.1.0.beta1]: https://github.com/hanami/hanami-webconsole/compare/v0.2.0...v2.1.0.beta1

## [0.2.0] - 2019-01-18

### Added

- Official support for Ruby 2.6.0. (@jodosha)
- Support for `bundler` 2.0+. (@jodosha)

[0.2.0]: https://github.com/hanami/hanami-webconsole/compare/v0.1.0...v0.2.0

## [0.1.0] - 2018-04-11

[0.1.0]: https://github.com/hanami/hanami-webconsole/compare/v0.1.0.rc2...v0.1.0

## [0.1.0.rc2] - 2018-04-06

[0.1.0.rc2]: https://github.com/hanami/hanami-webconsole/compare/v0.1.0.rc1...v0.1.0.rc2

## [0.1.0.rc1] - 2018-03-30

[0.1.0.rc1]: https://github.com/hanami/hanami-webconsole/compare/v0.1.0.beta2...v0.1.0.rc1

## [0.1.0.beta2] - 2018-03-23

[0.1.0.beta2]: https://github.com/hanami/hanami-webconsole/compare/v0.1.0.beta1...v0.1.0.beta2

## [0.1.0.beta1] - 2018-02-28

### Added

- Package as Hanami plugin. (@jodosha & Anton Davydov)

[0.1.0.beta1]: https://github.com/hanami/hanami-webconsole/releases/tag/v0.1.0.beta1
