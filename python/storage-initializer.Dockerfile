ARG PYTHON_VERSION=3.11
ARG BASE_IMAGE=python:${PYTHON_VERSION}-slim-bookworm
ARG VENV_PATH=/prod_venv

FROM ${BASE_IMAGE} AS builder

# Define the ARGs
ARG ARTIFACTORY_USER
ARG ARTIFACTORY_TOKEN

# Set environment variables from ARGs
ENV ARTIFACTORY_USER=${ARTIFACTORY_USER}
ENV ARTIFACTORY_TOKEN=${ARTIFACTORY_TOKEN}


# Install Poetry
ARG POETRY_HOME=/opt/poetry
ARG POETRY_VERSION=1.8.3
ARG CARGO_HOME=/opt/.cargo/

# Install necessary dependencies for building packages for ppc64le and other architecture-specific setup
RUN apt-get update && apt-get install -y --no-install-recommends python3-dev build-essential && \
    if [ "$(uname -m)" = "ppc64le" ]; then \
       echo "Installing packages and rust " && \
       apt-get install -y libopenblas-dev libssl-dev pkg-config curl libhdf5-dev cmake gfortran && \
       curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > sh.rustup.rs && \
       export CARGO_HOME=${CARGO_HOME} && sh ./sh.rustup.rs -y && export PATH=$PATH:${CARGO_HOME}/bin && . "${CARGO_HOME}/env"; \
    fi && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Poetry
ENV PATH="$PATH:${POETRY_HOME}/bin:${CARGO_HOME}/bin"
RUN python3 -m venv ${POETRY_HOME} && ${POETRY_HOME}/bin/pip install poetry==${POETRY_VERSION}

# Activate virtual env
ARG VENV_PATH
ENV VIRTUAL_ENV=${VENV_PATH}
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"


####### For Testing
RUN pip install numpy==1.26.4 --extra-index-url "https://${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}@na.artifactory.swg-devops.com/artifactory/api/pypi/sys-linux-power-team-ftp3distro-odh-pypi-local/simple/"
RUN curl -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}" \
    "https://na.artifactory.swg-devops.com/artifactory/api/pypi/sys-linux-power-team-ftp3distro-odh-pypi-local/simple/numpy"
RUN curl -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}" \
"https://na.artifactory.swg-devops.com/artifactory/api/pypi/sys-linux-power-team-ftp3distro-odh-pypi-local/numpy/1.26.4/numpy-1.26.4-cp311-cp311-manylinux_2_34_ppc64le.whl" \
--silent --head -w "%{http_code}\n" --output /dev/null


# Copy pyproject.toml and poetry.lock for dependency installation
COPY kserve/pyproject.toml kserve/poetry.lock kserve/


# RUN cd kserve && \
#     if [ $(uname -m) = "ppc64le" ]; then \
#        export GRPC_PYTHON_BUILD_SYSTEM_OPENSSL=true; \
#     fi && \
#     poetry install --no-root --no-interaction --no-cache --extras "storage"

RUN cd kserve && \
    poetry config repositories.odh-pypi-local "https://${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}@na.artifactory.swg-devops.com/artifactory/api/pypi/sys-linux-power-team-ftp3distro-odh-pypi-local/simple/" && \
    poetry config http-basic.odh-pypi-local $ARTIFACTORY_USER $ARTIFACTORY_TOKEN && \
    cat ~/.config/pypoetry/config.toml && \
    poetry config --list && \
    if [ $(uname -m) = "ppc64le" ]; then \
        GRPC_PYTHON_BUILD_SYSTEM_OPENSSL=true; \
    fi && \
    poetry install --no-root --no-interaction --no-cache --extras "storage" -vvv

# Copy the actual source code after dependencies are installed
COPY kserve kserve
RUN cd kserve && poetry install --no-interaction --no-cache --extras "storage"

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    gcc \
    libkrb5-dev \
    krb5-config \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir krbcontext==0.10 hdfs~=2.6.0 requests-kerberos==0.14.0

FROM ${BASE_IMAGE} AS prod

COPY third_party third_party

# Activate virtual env
ARG VENV_PATH
ENV VIRTUAL_ENV=${VENV_PATH}
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN useradd kserve -m -u 1000 -d /home/kserve

# Copy virtualenv and code from the builder stage
COPY --from=builder --chown=kserve:kserve $VIRTUAL_ENV $VIRTUAL_ENV
COPY --from=builder kserve kserve
COPY ./storage-initializer /storage-initializer

RUN chmod +x /storage-initializer/scripts/initializer-entrypoint
RUN mkdir /work
WORKDIR /work

# Set a writable /mnt folder to avoid permission issues on Huggingface download
RUN chown -R kserve:kserve /mnt
USER 1000
ENTRYPOINT ["/storage-initializer/scripts/initializer-entrypoint"]
