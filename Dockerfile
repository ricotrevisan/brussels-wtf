# syntax=docker/dockerfile:1
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5
ARG DEBIAN_VERSION=bookworm-20260610-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

RUN mix compile
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
ARG SOURCE_COMMIT=unknown
RUN printf '%s\n' "$SOURCE_COMMIT" > priv/source_commit
RUN mix release

# Prove release-owned corpus paths resolve after the compiler tree is unavailable.
RUN set -eu; \
  build_priv=/app/_build/prod/lib/brussels_wtf/priv; \
  mv "$build_priv" "${build_priv}.hidden"; \
  trap 'mv "${build_priv}.hidden" "$build_priv"' EXIT; \
  REVIEW_USERNAME=release-check \
  REVIEW_PASSWORD=release-check-password \
  DATABASE_URL=ecto://release:release@127.0.0.1/release \
  SECRET_KEY_BASE=0000000000000000000000000000000000000000000000000000000000000000 \
  /app/_build/prod/rel/brussels_wtf/bin/brussels_wtf eval \
    'unless byte_size(BrusselsWtf.Corpus.Manifest.digest()) == 64, do: System.halt(1)'

FROM ${RUNNER_IMAGE} AS runner

# Coolify supplies SOURCE_COMMIT for Git deployments; expose it through the
# unauthenticated health version endpoint so a rollout can prove its exact image.
ARG SOURCE_COMMIT=unknown
ENV RELEASE_SHA=${SOURCE_COMMIT}

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
    libstdc++6 openssl libncurses6 locales ca-certificates curl coreutils util-linux \
    poppler-utils ocrmypdf tesseract-ocr tesseract-ocr-fra tesseract-ocr-nld \
    tesseract-ocr-osd qpdf ghostscript \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod \
    PORT=3000

WORKDIR /app
RUN chown nobody:root /app
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/brussels_wtf ./

# Exercise mandate HTML parsing (including its native library) in the runner,
# then the sealed normalizer with the production Poppler output.
RUN REVIEW_USERNAME=release-check \
  REVIEW_PASSWORD=release-check-password \
  DATABASE_URL=ecto://release:release@127.0.0.1/release \
  SECRET_KEY_BASE=0000000000000000000000000000000000000000000000000000000000000000 \
  /app/bin/brussels_wtf eval \
    '["/mandats-2024.pdf"] = "<a href=\"/mandats-2024.pdf\">Mandates</a>" |> LazyHTML.from_document() |> LazyHTML.query("a[href]") |> LazyHTML.attribute("href"); for meeting <- BrusselsWtf.Corpus.Manifest.load!()["meetings"], source <- meeting["sources"] do bytes = File.read!(BrusselsWtf.Corpus.Manifest.bundle_path!(source)); {:ok, extracted} = BrusselsWtf.PDF.PopplerOcr.native(%{sha256: source["sha256"], media_type: source["media_type"]}, bytes); {:ok, _normalized} = BrusselsWtf.Corpus.Manifest.normalize(%{"sha256" => source["sha256"], "text" => extracted.text}) end'

USER nobody
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD if [ "${PROCESS_ROLE:-app}" = "ocr" ]; then /app/bin/ocr_ready; else curl --fail --silent --show-error "http://127.0.0.1:${PORT}/health/ready"; fi
CMD ["sh", "-c", "case ${PROCESS_ROLE:-app} in app) /app/bin/migrate && /app/bin/validate && /app/bin/server ;; ocr) /app/bin/validate && /app/bin/ocr_worker ;; *) echo invalid-process-role >&2; exit 64 ;; esac"]
