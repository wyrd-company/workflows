# kaizen-collect

Collects every finished UTC day of agent exchanges that is not yet collected, from ClickHouse into the Kaizen analysis store and the private archive bucket. No model runs in it.

The collection code is in the kaizen repository's `collect/` folder, whose README describes the store. This workflow schedules it.

## When it runs

Nightly at 01:00 UTC. A day is collected after it ends, with an hour for rows that arrive late. A night that fails or is missed needs no rerun: the next run collects every day that is still missing.

## Run it by hand

```sh
dagu start kaizen-collect                       # every missing day
dagu start kaizen-collect -- DAY=2026-01-02     # that day again
```

## What it needs

- The kaizen repository's main checkout at `/workspace/kaizen/kaizen/main`. The run fast-forwards it when it is a clean checkout of `main`, and runs it as it is otherwise, with a line saying so.
- The Wyrwood SSH agent, for the ClickHouse identity.
- The Wyrwood vault socket, for the bucket's key.
- `uv`, which fetches DuckDB on first use.

## Reading a run

The step prints one JSON line for each day, with its row counts and data gaps, and a last line listing the days collected and the days that failed. The run fails when any day failed.

## Test

```sh
tests/kaizen-collect/run.sh
```
