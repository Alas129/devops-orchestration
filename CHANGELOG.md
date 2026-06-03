# Changelog

## [0.1.0](https://github.com/Alas129/devops-orchestration/compare/v0.0.1...v0.1.0) (2026-06-03)


### Features

* **auth-svc:** annotate startup log with build marker ([0696dc6](https://github.com/Alas129/devops-orchestration/commit/0696dc63ced94924a1dd110cb7c2095f3f3c6839))
* **auth-svc:** annotate startup log with build marker ([19e07d6](https://github.com/Alas129/devops-orchestration/commit/19e07d6732e1ff5e6155fb3ac2f45a2bdac76a72))
* **ci:** inject SLACK_WEBHOOK_URL env var, reject placeholder values ([2dd63a0](https://github.com/Alas129/devops-orchestration/commit/2dd63a00f37ac927be00505d43c0be431e2637b7))
* **db-bootstrap:** provision app schemas+tables+DML grants ([c4d33c4](https://github.com/Alas129/devops-orchestration/commit/c4d33c4b2a9cb0f0983e085583c7d1f3feb2f82e))
* **frontend:** stats dashboard, 7-day activity chart, filter tabs, delete, user bar ([753ee66](https://github.com/Alas129/devops-orchestration/commit/753ee660e493afda64b2b2cbb2a950570f9ebb65))
* modified the gitops part and optimized the argocd usage ([f797d59](https://github.com/Alas129/devops-orchestration/commit/f797d5964ea5ddfaf99ca2e2bf93e057df24b1e7))
* **observability,prod:** node critical alerts + prod overlay scaffolding ([f97a6f5](https://github.com/Alas129/devops-orchestration/commit/f97a6f50785dcb868c20732c2b590051cd92837d))
* optimized the infra processes and updated the tools and terraform modules ([96681a8](https://github.com/Alas129/devops-orchestration/commit/96681a8fea7b31653ac01bbb4179dea88f1eb1af))


### Bug Fixes

* **charts:** add protocol TCP to container ports for SSA diff ([e19a716](https://github.com/Alas129/devops-orchestration/commit/e19a716ac4d4924bc4453fdf86d0849ed115c8a6))
* **charts:** short DNS for backend API + guard empty Prometheus result ([afcc70d](https://github.com/Alas129/devops-orchestration/commit/afcc70d7dda366414f9b5f7d1d419e7b5f4fb3b5))
* **ci:** grant id-token/security-events to Go-svc CIs + skip 3rd-party CRDs ([4d7cfde](https://github.com/Alas129/devops-orchestration/commit/4d7cfde6f0b846d35a1de1175d2111fda09793bd))
* **ci:** promote-uat/prod read image refs from upstream overlay instead of release tag ([6ea3491](https://github.com/Alas129/devops-orchestration/commit/6ea3491612868a07bf8d9c67615222f42b7e1c5a))
* **ci:** use block scalar for slack-notify run steps (YAML colon-in-string bug) ([b67f843](https://github.com/Alas129/devops-orchestration/commit/b67f8431d2d68eebb6ab17eb83e99a1ed37d5ceb))
* end-to-end demo path — DB TLS sslmode override + ESO SecretsManager ([0e7cdd1](https://github.com/Alas129/devops-orchestration/commit/0e7cdd17fe4a924a0082aba37f63e5d2e7ac5504))
* **frontend:** use short Service DNS in next.config.mjs rewrites (eval at build time) ([81d76bc](https://github.com/Alas129/devops-orchestration/commit/81d76bc34f7a1d7971553db2ec799bc14e350fdb))
* **karpenter:** IRSA trust must match kube-system:karpenter SA path ([3c3748d](https://github.com/Alas129/devops-orchestration/commit/3c3748d6fec17c61f701c441e7e3f0e32f13c31e))
* **monitoring:** remove invalid smtp_auth_*_file fields from Alertmanager ([2055839](https://github.com/Alas129/devops-orchestration/commit/2055839d0debbf68b56a76178ec6a28625d68fc6))
* move postgres role mgmt out of TF, prep gitops/platform for App-of-Apps ([efa24e2](https://github.com/Alas129/devops-orchestration/commit/efa24e26d119e872912fdc6ec9fbcc1d55398072))
* **oidc:** allow environment-based subs ([a9d068a](https://github.com/Alas129/devops-orchestration/commit/a9d068a1710de508ef0fd8b6db67bad004439f32))
* split ALB target-group vs load-balancer attrs + pin frontend UID ([717024b](https://github.com/Alas129/devops-orchestration/commit/717024bc2a69aacd7700700758f2bd0b34f5b525))
* **tasks-svc,notifier-svc:** refresh RDS IAM auth token on reconnect ([030788f](https://github.com/Alas129/devops-orchestration/commit/030788f1b110f669480c016de7b4fa84bc4d239f))
* **tasks-svc,notifier-svc:** refresh RDS IAM auth token on reconnect ([a0b64a1](https://github.com/Alas129/devops-orchestration/commit/a0b64a1fccd01ca4d2b61e264ec5276cbee0add1))
* **tf+ci:** nonprod plan errors and release-please PAT ([1c0ee88](https://github.com/Alas129/devops-orchestration/commit/1c0ee88c1318cc3668820e7cce3dfdb7e5b68e77))
* use built-in node user instead of conflicting gid 1000 ([74bdc95](https://github.com/Alas129/devops-orchestration/commit/74bdc956648984f4ca8e2985bd86ea33c27ae837))
