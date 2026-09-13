FROM erlang:29-alpine

RUN apk add --no-cache build-base git sqlite-dev
WORKDIR /opt/erlite
COPY . .
RUN rebar3 compile && mkdir -p /opt/read-benchmark/ebin && \
    erlc -Werror -o /opt/read-benchmark/ebin \
      tools/read-benchmark/src/erlite_read_bench_node.erl \
      tools/read-benchmark/src/erlite_read_bench.erl

ENV ERL_LIBS=/opt/erlite/_build/default/lib
ENV ERLITE_BENCH_COOKIE=erlite-read-benchmark
