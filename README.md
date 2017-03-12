# rb-opentracers

A set of Ruby-compatible tracers conforming to the [OpenTracing](http://opentracing.io/)
API. Supported reporters include:

* `Logging`, which logs via any `Logger`-compatible logger.
* `Zipkin`, which sends spans to a [Zipkin](http://zipkin.io/) server.
* `AppDash` (currently unfinished), which sends spans to an [AppDash](https://github.com/sourcegraph/appdash) server.

The `opentracing` gem itself includes a no-op Tracer
(`OpenTracing.global_tracer = OpenTracing::Tracer.new`), so one is not provided
here.

This gem is (intended to be) thread-safe and deadlock-free.

## Installation

## Configuration

1. Decide on a reporter. Each one requires different configuration. E.g.
   `my_reporter = Tracer::Reporter::Logging.new(logger: Logger.new('trace_log.out'), log_level: :debug)`
1. In the case of a multi-process server, you want to set up your
   tracer *after* the worker boots. Unicorn and Puma provide facilities
   to do this. Reporters are written to be thread-safe, so no special
   handling is necessary in the case of new threads.
1. To set your tracer; `OpenTracing::global_tracer = ::Tracer::Tracer.new(reporter: my_reporter)`

## Usage

The [OpenTracing API](https://github.com/opentracing/opentracing-ruby) is available.

While not included in the gem, some potentially useful helper methods can be
seen at <https://gist.github.com/xxx/3b9f6d8ab057507df608f390ed0ec394>.

## Status

* Currently hackerware. There are no tests, and I have no idea if I'm correctly
  mapping OpenTracing concepts to the various backends.

* Tracers and reporters are thread safe, but not fork safe. If you are
  forking processes, you'll need to clear the spans from the child
  process' reporter, or you'll get duplicate spans reported. In the case
  of some application servers, they offer hooks to run after a new process
  forks, so you could use that to reinitialize the tracer entirely.
  
* The Appdash reporter is unfinished, and completely broken at the moment.
  
## Contributing

* Feel free to send pull requests.

* Don't be a dick. If a contributor to this project is being one, feel free to
  contact me (@xxx) privately via any mechanism. I'm not tolerant of jerks, and
  will remove them from the project immediately, regardless of past contributions.

## Acknowledgements

* [OpenTracing](http://opentracing.io)
  * Without which, we wouldn't be here.
* [appdash-rb](https://github.com/bsm/appdash-rb)
  * A bunch of the protobuf handling was taken directly from here.
* [lightstep](https://github.com/lightstep/lightstep-tracer-ruby)
  * I took inspiration, and code for injecting and extracting spans
    from this already-OT-compatible gem. It also
    includes an example of a fork-safe reporter, should you want to
    add that locally.

## License

See LICENSE.txt (tl;dr: MIT)