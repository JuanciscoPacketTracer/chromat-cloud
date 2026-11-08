# Initial deployment baseline for CHROMAT

**Research date/access date:** 2026-11-07  
**Purpose:** support selection of an initial deployment baseline for the work around
GitHub issue [#3](https://github.com/JuanciscoPacketTracer/chromat-cloud/issues/3);
this note records the compatibility research requested by that ticket.

## Context

The repository describes a local Ubuntu Server virtual machine running Docker
Compose, with Node.js, Python inference, and MariaDB services
([README.md](https://github.com/JuanciscoPacketTracer/chromat-cloud/blob/main/README.md),
accessed 2026-11-07). Issue #3 asks for a concrete Ubuntu Server LTS and a
minimum compatibility matrix covering Docker Engine/Compose, Node.js/Python,
MariaDB, and x86_64 CPU processing
([issue #3](https://github.com/JuanciscoPacketTracer/chromat-cloud/issues/3),
accessed 2026-11-07).

## Recommendation

Use the following initial target for an x86_64/amd64 server:

| Layer | Initial baseline | Rationale |
|---|---|---|
| Host OS | **Ubuntu Server 26.04 LTS, 64-bit** | As of the research date, Canonical lists 26.04 LTS as released in April 2026 with standard security maintenance through May 2031; Canonical recommends LTS releases for production and long-lived projects. ([Ubuntu release cycle](https://ubuntu.com/about/release-cycle), accessed 2026-11-07.) |
| Container runtime | **Docker Engine from Docker's official Ubuntu apt repository** | Docker officially supports 64-bit Ubuntu 26.04 LTS and lists x86_64/amd64 among supported architectures. ([Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/), accessed 2026-11-07.) |
| Orchestration CLI | **Docker Compose plugin, installed with Docker's repository package** | Docker documents `docker-compose-plugin` as the Linux installation path and verifies it with `docker compose version`. ([Compose plugin installation](https://docs.docker.com/compose/install/linux/), accessed 2026-11-07.) |
| Node.js service | **Node.js 26 Active LTS, pinned to an explicit patch image tag** | The Node.js Release Working Group lists 26.x as Active LTS with an end-of-life date of 2029-04-30. The Docker Official Image metadata provides Node 26 tags with an `amd64` variant. ([Node release schedule](https://github.com/nodejs/Release/blob/main/README.md), accessed 2026-11-07; [official Node image metadata](https://github.com/docker-library/official-images/blob/master/library/node), accessed 2026-11-07.) |
| Python inference service | **Python 3.13 or 3.14, selected after dependency testing, pinned to an explicit patch image tag** | The Python project documents separate feature, bugfix, security, and end-of-life phases; the official Python image metadata lists both 3.13 and 3.14 tags with `amd64` variants. Keeping this choice configurable avoids assuming that the image-classification dependency set is ready for the newest interpreter. ([Python version status](https://devguide.python.org/versions/), accessed 2026-11-07; [official Python image metadata](https://github.com/docker-library/official-images/blob/master/library/python), accessed 2026-11-07.) |
| Database | **MariaDB 11.8, pinned to an explicit patch image tag** | The MariaDB Official Image metadata lists 11.8 tags and an `amd64` variant. The image project is maintained by the MariaDB Foundation and community and identifies the official image as the Docker Library image. ([official MariaDB image metadata](https://github.com/docker-library/official-images/blob/master/library/mariadb), accessed 2026-11-07; [MariaDB Docker image source](https://github.com/MariaDB/mariadb-docker/blob/master/README.md), accessed 2026-11-07.) |
| CPU/architecture | **x86_64 (amd64)** | Docker Engine's Ubuntu requirements explicitly name x86_64/amd64, and the selected Node, Python, and MariaDB Official Image metadata all publish amd64 variants. ([Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/), accessed 2026-11-07; [Node metadata](https://github.com/docker-library/official-images/blob/master/library/node), accessed 2026-11-07; [Python metadata](https://github.com/docker-library/official-images/blob/master/library/python), accessed 2026-11-07; [MariaDB metadata](https://github.com/docker-library/official-images/blob/master/library/mariadb), accessed 2026-11-07.) |

## Operational guardrails for the baseline

* Install Docker Engine and Compose from the official apt repository rather
  than the convenience script for a production-like host; Docker says the
  convenience script is intended for testing and development and warns that it
  can install unexpected major versions. ([Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/), accessed 2026-11-07.)
* Pin image digests or explicit patch tags in the eventual Compose file. This
  is a recommendation for reproducibility; the cited official image metadata
  demonstrates that versioned tags and architectures are published, but does
  not by itself define CHROMAT's upgrade policy. ([Node metadata](https://github.com/docker-library/official-images/blob/master/library/node), accessed 2026-11-07; [Python metadata](https://github.com/docker-library/official-images/blob/master/library/python), accessed 2026-11-07; [MariaDB metadata](https://github.com/docker-library/official-images/blob/master/library/mariadb), accessed 2026-11-07.)
* Treat host firewalling as a deployment task: Docker warns that published
  container ports can bypass UFW/firewalld rules and recommends considering its
  packet-filtering behavior. ([Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/), accessed 2026-11-07.)

## Limitations and gaps

* This research establishes compatibility and support-oriented defaults only.
  It does not determine VM CPU count, memory, storage capacity, image-upload
  throughput, inference latency, backup retention, observability, TLS, or
  hardening requirements; those require project measurements and operational
  decisions.
* Python 3.13 versus 3.14 remains intentionally open until the actual
  inference dependencies are tested on amd64. The Python release policy
  distinguishes bugfix and security-only phases, but it does not certify
  compatibility for CHROMAT's future model stack. ([Python version status](https://devguide.python.org/versions/), accessed 2026-11-07.)
* MariaDB image architecture availability does not establish schema,
  SQL-mode, backup, migration, or compatibility decisions for the application.
  Those require separate implementation and data-contract work.
