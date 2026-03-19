# Changelog

## [0.2.0](https://github.com/juam-sv/kafka-lab/compare/kafka-lab-v0.1.0...kafka-lab-v0.2.0) (2026-03-19)


### Features

* add ALB Ingress with latency-based DNS routing via external-dns ([8c45d74](https://github.com/juam-sv/kafka-lab/commit/8c45d7448634b7df22df4642ec89c82b2efedbb1))
* add enabled flag for components/jobs and harden consumer ([fdc8b70](https://github.com/juam-sv/kafka-lab/commit/fdc8b70dec2075bb93e8790b95606ff8f1dff765))
* add KEDA/Karpenter stress test scripts and increase partitions … ([f7fd3ef](https://github.com/juam-sv/kafka-lab/commit/f7fd3efd47bde723f3eecfc58f9aea101d870d69))
* add KEDA/Karpenter stress test scripts and increase partitions to 10 ([e78a8ba](https://github.com/juam-sv/kafka-lab/commit/e78a8baea907a9453ece2c023273ee39813287c9))
* ALB Ingress with multi-region latency-based DNS ([2412cad](https://github.com/juam-sv/kafka-lab/commit/2412cadfe9f376b613cb615375adf529bd6785af))
* migrate CI from Docker Hub to AWS ECR with OIDC authentication ([eeb0e09](https://github.com/juam-sv/kafka-lab/commit/eeb0e09a2ec6434f4352fc1582e9199abf0a6cee))
* migrate CI from Docker Hub to AWS ECR with OIDC authentication ([b39d6ff](https://github.com/juam-sv/kafka-lab/commit/b39d6ff3a54738c6f8220755b704011dd04cc39b))


### Bug Fixes

* add CACHE_PASSWORD for ElastiCache auth ([e0d298b](https://github.com/juam-sv/kafka-lab/commit/e0d298bea6332941073e3587e429d9537eac1a63))
* add CACHE_PASSWORD for ElastiCache auth ([4c48493](https://github.com/juam-sv/kafka-lab/commit/4c48493b02ad1ef8a8e513573724b9b7bc901459))
* add pod-level securityContext and readOnlyRootFilesystem for Trivy ([2475df4](https://github.com/juam-sv/kafka-lab/commit/2475df40f8a66fb16d03601dc9777c1b1512ade6))
* add security contexts to helm deployments to pass trivy config scan ([811866a](https://github.com/juam-sv/kafka-lab/commit/811866a637c6e1e3ea726e290f26356087d612b3))
* helm IRSA split, enabled flags, consumer error handling ([4784fe7](https://github.com/juam-sv/kafka-lab/commit/4784fe7093d5f4a3f52fd0cdd69ab5c3a9da7b2f))
* omit consumer replicas when KEDA manages scaling ([483d447](https://github.com/juam-sv/kafka-lab/commit/483d447d1b68b3744d91fe183466e4bb9582bff9))
* omit consumer replicas when KEDA manages scaling ([c7447a6](https://github.com/juam-sv/kafka-lab/commit/c7447a65884bdc683ce7d88b8abc00d6bb633238))
* resolve ruff lint and Trivy misconfig CI failures ([d786a5e](https://github.com/juam-sv/kafka-lab/commit/d786a5e4ca0ac68a6ba46b34fa400575bc8888ec))
* resolve ruff lint and Trivy misconfig CI failures ([a30acd4](https://github.com/juam-sv/kafka-lab/commit/a30acd4d9d2c7c902d0159c59a56f72970f0bae7))
* separate SA name from IAM role name to fix IRSA auth ([2260065](https://github.com/juam-sv/kafka-lab/commit/2260065c1a9204b8ac893510910339c9926f8ab9))
* separate SA name from IAM role name to fix IRSA auth ([418103e](https://github.com/juam-sv/kafka-lab/commit/418103e8d04a45ed812cfdcad43fad20668a3a83))
* switch cache from pymemcache to redis for Valkey/ElastiCache com… ([e8f1a5f](https://github.com/juam-sv/kafka-lab/commit/e8f1a5fb76b360cf2b8f78069b4a6c5e9b7d03c9))
* switch cache from pymemcache to redis for Valkey/ElastiCache compatibility ([f8f3dd2](https://github.com/juam-sv/kafka-lab/commit/f8f3dd297f515f356c05b3bb9a28e214d0bd6120))
