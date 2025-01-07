1. Prerequisites

* AWS CLI installed ([Installation Guide](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)).
* Elastic Beanstalk CLI (EB CLI) installed ([Installation Guide](https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/eb-cli3-install.html)).
* AWS account and configured credentials (`aws configure`).
* Your application code and a Dockerfile in the root directory.
* Update `ContainerPort` in Dockerrun.aws.json.

2. Run in terminal

* `eb init`
* `eb create <EnvironmentName>`
* Run `eb deploy` to update
