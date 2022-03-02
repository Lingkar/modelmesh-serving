# Copyright 2021 IBM Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

FROM registry.access.redhat.com/ubi8/ubi-minimal:8.4 as develop

ARG GOLANG_VERSION=1.17.3
ARG OPENSHIFT_VERSION=4.9
ARG KUSTOMIZE_VERSION=4.4.0
ARG KUBEBUILDER_VERSION=v3.2.0
ARG CONTROLLER_GEN_VERSION=v0.7.0
ENV PATH=/usr/local/go/bin:$PATH:/usr/local/kubebuilder/bin:

ARG TARGETARCH

USER root

WORKDIR /workspace

# Copy the Go Modules manifests
COPY .pre-commit-config.yaml go.mod go.sum ./

# Install gcc
RUN microdnf install \
    diffutils \
    gcc-c++ \
    make \
    wget \
    tar \
    vim \
    git \
    python38 \
    nodejs && \
    pip3 install pre-commit && \
# Install go
    set -eux; \
    wget -qO go.tgz "https://golang.org/dl/go${GOLANG_VERSION}.linux-${TARGETARCH}.tar.gz"; \
#    sha256sum *go.tgz; \
    tar -C /usr/local -xzf go.tgz; \
    go version && rm go.tgz && \
# Download and initialize the pre-commit environments before copying the source so they will be cached
    git init && \
    pre-commit install-hooks && \
    rm -rf .git && \
# Download kubebuilder
    true \
# First download and extract older dist of kubebuilder which includes required etcd, kube-apiserver and kubectl binaries
    && curl -L https://github.com/kubernetes-sigs/kubebuilder/releases/download/v2.3.2/kubebuilder_2.3.2_linux_${TARGETARCH}.tar.gz | tar -xz -C /tmp/ \
    && mv /tmp/kubebuilder_*_linux_${TARGETARCH} /usr/local/kubebuilder \
# Then download and overwrite kubebuilder binary with desired/latest version
    && curl -L https://github.com/kubernetes-sigs/kubebuilder/releases/download/${KUBEBUILDER_VERSION}/kubebuilder_linux_${TARGETARCH} -o /usr/local/kubebuilder/bin/kubebuilder \
    && true && \
# download openshift-cli
    curl -sSLf --output /tmp/oc_client.tar.gz https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest-${OPENSHIFT_VERSION}/openshift-client-linux.tar.gz \
    && tar -xvf /tmp/oc_client.tar.gz -C /tmp \
    && mv /tmp/oc /usr/local/bin \
    && mv /tmp/kubectl /usr/local/bin \
    && chmod a+x /usr/local/bin/oc /usr/local/bin/kubectl \
    && rm -f /tmp/oc_client.tar.gz && \
# download kustomize
    curl -sSLf --output /tmp/kustomize.tar.gz https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_${TARGETARCH}.tar.gz \
    && tar -xvf /tmp/kustomize.tar.gz -C /tmp \
    && mv /tmp/kustomize /usr/local/bin \
    && chmod a+x /usr/local/bin/kustomize \
    && rm -v /tmp/kustomize.tar.gz && \
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
    go mod download && \
# Install controller-gen
    mkdir /tmp/controller-gen-tmp && cd /tmp/controller-gen-tmp \
    && go mod init tmp && go get sigs.k8s.io/controller-tools/cmd/controller-gen@${CONTROLLER_GEN_VERSION} \
    && rm -rf /tmp/controller-gen-tmp


###############################################################################
# Stage 1: Run the build
###############################################################################
FROM develop AS build

LABEL image="build"

# Copy the go source
COPY main.go main.go
COPY apis/ apis/
COPY controllers/ controllers/
COPY generated/ generated/
COPY pkg/ pkg/

ARG TARGETARCH

# Build
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} GO111MODULE=on go build -a -o manager main.go

###############################################################################
# Stage 2: Copy build assets to create the smallest final runtime image
###############################################################################
FROM registry.access.redhat.com/ubi8/ubi-minimal:8.4 AS runtime

ARG USER=2000
ARG IMAGE_VERSION
ARG COMMIT_SHA


LABEL name="modelmesh-serving-controller" \
      version="${IMAGE_VERSION}" \
      release="${COMMIT_SHA}" \
      summary="Kubernetes controller for ModelMesh Serving components" \
      description="Manages lifecycle of ModelMesh Serving Custom Resources and associated Kubernetes resources"

USER root

WORKDIR /
COPY --from=build /workspace/manager .

COPY config/internal config/internal

ENTRYPOINT ["/manager"]
