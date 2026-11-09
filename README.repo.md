## Installation

Add this line to your Hanami project's `Gemfile`:

```ruby
group :development do
  gem "hanami-webconsole"
end
```

And then execute:

```shell
$ bundle install
```

**NOTE:** Use the same major version of `hanami` and `hanami-webconsole`.

## Usage

When an exception is raised during your local development in-browser, you'll see the web console. Hanami adds the web console automatically in development when this gem is bundled.

### Code reloading

Hanami reloads code by restarting the server (using [`hanami-reloader`](https://rubygems.org/gems/hanami-reloader)), so web console sessions don't survive a reload. Start the server as usual with `bundle exec hanami dev` or `bundle exec hanami server`.

## Development

After checking out the repo, run `bin/setup` to install dependencies.
You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

To run all the test, use `script/ci`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/hanami/hanami-webconsole.

## Acknowledgements

This gem is based on the great work of [`better_errors`](https://rubygems.org/gems/better_errors) and [`binding_of_caller`](https://rubygems.org/gems/binding_of_caller) gems. Thank you!
