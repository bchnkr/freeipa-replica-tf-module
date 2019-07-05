# The IPA master EC2 instance
resource "aws_instance" "ipa_master" {
  ami               = data.aws_ami.freeipa.id
  instance_type     = var.aws_instance_type
  availability_zone = "${var.aws_region}${var.aws_availability_zone}"
  subnet_id         = var.subnet_id
  vpc_security_group_ids = [
    aws_security_group.ipa_servers.id,
  ]

  user_data_base64 = data.template_cloudinit_config.freeipa_cloud_init_tasks.rendered

  tags        = var.tags
  volume_tags = var.tags
}

# This is the Terraform configuration for the EBS volume that will
# contain the production IPA data. Therefore we need these resources
# to be immortal in any "production" workspace, and so I am using the
# prevent_destroy lifecycle element to disallow the destruction of it
# via terraform in that case.
#
# I'd like to use "${terraform.workspace == "production" ? true :
# false}", so the prevent_destroy only applies to the production
# workspace, but it appears that interpolations are not supported
# inside of the lifecycle block
# (https://github.com/hashicorp/terraform/issues/3116).
resource "aws_ebs_volume" "ipa_data" {
  availability_zone = "${var.aws_region}${var.aws_availability_zone}"
  type              = "gp2"
  size              = 10
  encrypted         = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "ipa_data_attachment" {
  device_name = "/dev/xvdb"
  volume_id   = aws_ebs_volume.ipa_data.id
  instance_id = aws_instance.ipa_master.id

  # Terraform attempts to destroy the volume attachments before it
  # attempts to destroy the EC2 instance they are attached to.  EC2
  # does not like that and it results in the failed destruction of the
  # volume attachments.  To get around this, we explicitly terminate
  # the ipa_data instance via the AWS CLI in a destroy provisioner;
  # this gracefully shuts down the instance and allows terraform to
  # successfully destroy the volume attachments.
  provisioner "local-exec" {
    when       = destroy
    command    = "aws --region=${var.aws_region} ec2 terminate-instances --instance-ids ${aws_instance.ipa_master.id}"
    on_failure = continue
  }

  # Wait until the instance is terminated before continuing on
  provisioner "local-exec" {
    when    = destroy
    command = "aws --region=${var.aws_region} ec2 wait instance-terminated --instance-ids ${aws_instance.ipa_master.id}"
  }

  skip_destroy = true
}