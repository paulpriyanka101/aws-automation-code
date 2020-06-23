provider "aws" {
	region = "ap-south-1"
	profile = "admin"
}

# create a key-pair to login to EC2 instance

resource "tls_private_key" "webappkey" {
	algorithm = "RSA"
	rsa_bits = 4096
}

resource "local_file" "private_key" {
	content = tls_private_key.webappkey.private_key_pem
	filename = "${path.module}/webappkey.pem"
	file_permission = 0400
}

resource "aws_key_pair" "webappkey" {
	key_name = "webappkey"
	public_key = tls_private_key.webappkey.public_key_openssh
}

# create a SG and allow SSH, HTTP and ICMP ports:

resource "aws_security_group" "webappsg" {
	name = "webappsg"
	description = "Security group for webapp applications"
ingress {
	description = "SSH"
	from_port = 22
	to_port = 22
	cidr_blocks = ["0.0.0.0/0"]
	protocol = "tcp"
	}
ingress {
	description = "HTTP"
	from_port =80
	to_port = 80
	cidr_blocks = ["0.0.0.0/0"]
	protocol = "tcp"
	}
ingress {
	description = "ping-icmp"
	from_port = -1
	to_port = -1
	cidr_blocks = ["0.0.0.0/0"]
	protocol = "icmp"
	}
egress {
	from_port = 0
	to_port = 0
	cidr_blocks = ["0.0.0.0/0"]
	protocol = -1
	}
}

# create EC2 instance

resource "aws_instance" "webappos1" {
	ami = "ami-0447a12f28fddb066"
	instance_type = "t2.micro"
	key_name = aws_key_pair.webappkey.key_name
	security_groups = [ "webappsg" ]
	
connection {
	type = "ssh"
	user = "ec2-user"
	private_key = tls_private_key.webappkey.private_key_pem
	host = aws_instance.webappos1.public_ip
}

provisioner "remote-exec" {
	inline = [
		"sudo yum install httpd php git -y",
		"sudo systemctl start httpd",
		"sudo systemctl enable httpd",
	]
}
tags = {
	Name = "webappos1"
	}
}
resource "null_resource" "nulllocal1" {

provisioner "local-exec" {
	command = "echo ${aws_instance.webappos1.public_ip} > ip_addr.txt"
	}
}

# create EBS volume and attach it to instance

resource "aws_ebs_volume" "datavol1" {
	availability_zone = aws_instance.webappos1.availability_zone
	size = 2
	tags = {
		Name = "datavol1"
	}
}

resource "aws_volume_attachment" "vol_attach" {
	device_name = "/dev/sdb"
	volume_id = aws_ebs_volume.datavol1.id
	instance_id = aws_instance.webappos1.id
	force_detach = true
	}

resource "null_resource" "nulllocal3" {
provisioner "local-exec" {
	command = "echo ${aws_ebs_volume.datavol1.id} > datavolume-id.txt"
	}
}

resource "null_resource" "nullremote1" {

depends_on = [
	aws_volume_attachment.vol_attach
	]
connection {
	type = "ssh"
	user = "ec2-user"
	private_key = tls_private_key.webappkey.private_key_pem
	host = aws_instance.webappos1.public_ip
	}

provisioner "remote-exec" {
	inline = [
		"sudo mkfs.ext4 /dev/xvdb ",
		"sudo mount /dev/xvdb  /var/www/html",
		"sudo rm -rf  /var/www/html*",
		"sudo git clone https://github.com/paulpriyanka101/aws-automation-code.git /var/www/html"
	]
  }
}

resource "null_resource" "nulllocal2" {

depends_on = [
	null_resource.nullremote1,
	]

provisioner "local-exec" {
	command = "open http://${aws_instance.webappos1.public_ip}"
	}
}

# create S3 bucket and upload image from GitHub

resource "aws_s3_bucket" "staticimagebucket123" {
	
	bucket = "staticimagebucket123"
	acl = "public-read"

provisioner "local-exec" {
	command = "git clone https://github.com/paulpriyanka101/aws-automation-code.git aws-automation-code"

	}

provisioner "local-exec" {
	when = destroy
	command = "rm -rf aws-automation-code"
	}
}
	
resource "aws_s3_bucket_object" "staticimagebucketobject" {
	bucket = aws_s3_bucket.staticimagebucket123.bucket
	key = "download.jpeg"
	source = "aws-automation-code/download.jpeg"
	content_type = "image/jpeg"
	acl = "public-read"
	depends_on = [
		aws_s3_bucket.staticimagebucket123
	]
 }
locals {
	s3_origin_id = "S3-${aws_s3_bucket.staticimagebucket123.bucket}"
	}


# Cloud-front creation

resource "aws_cloudfront_distribution" "mycloudfront" {
	
	origin {
		domain_name = aws_s3_bucket.staticimagebucket123.bucket_regional_domain_name
		origin_id = "locals.s3_origin_id"
	custom_origin_config {
		http_port = 80
		https_port = 443
		origin_protocol_policy = "match-viewer"
		origin_ssl_protocols = ["TLSv1", "TLSv1.1", "TLSv1.2"]
		}
	  }

enabled = true
is_ipv6_enabled = true

default_cache_behavior {
	allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
	cached_methods = ["GET", "HEAD"]
	target_origin_id = "locals.s3_origin_id"

	forwarded_values {
		query_string = false

		cookies{
			forward = "none"
		}
	}

		viewer_protocol_policy = "allow-all"
		min_ttl = 0
		default_ttl = 3600
		max_ttl = 86400
	}
restrictions {
	geo_restriction {
		restriction_type = "none"
	}
}

viewer_certificate {
	cloudfront_default_certificate = true
}

connection {
	type = "ssh"
	user = "ec2-user"
	private_key = tls_private_key.webappkey.private_key_pem
	host = aws_instance.webappos1.id
	}

provisioner "remote-exec" {
	inline = [
	"sudo su << EOF",
	"echo \"<img src = 'http://${self.domain_name}/{aws_s3_bucket_object.staticimagebucketobject.key}'>\" >> /var/www/html/index.php",
	"EOF"
	]
  }
}



		