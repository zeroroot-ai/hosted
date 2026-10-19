# The backend is configured per environment at init time, the same way
# bootstrap/eks/gibson does it: the bucket name carries the account id, so it
# is supplied by -backend-config rather than committed here.
terraform {
  backend "s3" {
    region  = "us-east-1"
    encrypt = true
  }
}
