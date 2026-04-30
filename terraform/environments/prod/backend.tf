terraform {
  backend "s3" {
    bucket         = "production-platform-tfstate-prod"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "production-platform-tfstate-lock"
    encrypt        = true
  }
}
