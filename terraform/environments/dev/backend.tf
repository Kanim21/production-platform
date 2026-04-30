terraform {
  backend "s3" {
    bucket         = "production-platform-tfstate-dev"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "production-platform-tfstate-lock"
    encrypt        = true
  }
}
