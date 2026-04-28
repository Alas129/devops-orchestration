# Bootstrap

One-time, runs against **local state**. Creates the S3 bucket + DynamoDB
table that every other Terraform env uses as a backend.

```sh
terraform init
terraform apply
```

After this, every env (`_shared`, `nonprod`, `prod`) sets the S3 backend
referencing the bucket+table outputs from here. The bucket is set
`prevent_destroy = true` — destroying state would orphan every other env.
