provider "aws" {
  region  = "ap-south-1"
  profile = "default"
}

resource "aws_vpc" "task_vpc" {
  cidr_block       = "192.168.0.0/24"
  instance_tenancy = "default"
  tags = {
    Name = "Task-2-VPC"
  }
}

resource "aws_subnet" "subnet_1a" {
  depends_on = [aws_vpc.task_vpc]

  vpc_id                  = aws_vpc.task_vpc.id
  cidr_block              = "192.168.0.0/24"
  availability_zone       = "ap-south-1a"
  map_public_ip_on_launch = true
  tags = {
    Name = "subnet_1a"
  }
}

resource "aws_internet_gateway" "task_ig" {
  depends_on = [aws_vpc.task_vpc]

  vpc_id = aws_vpc.task_vpc.id
  tags = {
    Name = "task_ig"
  }
}

resource "aws_route_table" "task_rt" {

  depends_on = [aws_internet_gateway.task_ig]

  vpc_id = aws_vpc.task_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.task_ig.id
  }
}
resource "aws_route_table_association" "subnet-association-1a" {

  depends_on     = [aws_route_table.task_rt]
  subnet_id      = aws_subnet.subnet_1a.id
  route_table_id = aws_route_table.task_rt.id
}
resource "aws_main_route_table_association" "subnet-main-rt-association-1a" {

  depends_on = [aws_route_table_association.subnet-association-1a]

  vpc_id         = aws_vpc.task_vpc.id
  route_table_id = aws_route_table.task_rt.id
}

resource "aws_security_group" "task_sg" {
  name   = "sg_task_2"
  vpc_id = aws_vpc.task_vpc.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "NFS"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sg_task_2"
  }
}

resource "aws_efs_file_system" "efs_storage" {
  creation_token = "task_storage"
  tags = {
    Name = "task-2-storage"
  }
}

resource "aws_efs_file_system_policy" "efs_policy" {

  depends_on = [aws_efs_file_system.efs_storage]

  file_system_id = aws_efs_file_system.efs_storage.id
  policy         = <<POLICY
{
    "Version": "2012-10-17",
    "Id": "efs-storage-read-write-permission-Policy01",
    "Statement": [
        {
            "Sid": "efs-statement-permission01",
            "Effect": "Allow",
            "Principal": {
                "AWS": "*"
            },
            "Resource": "${aws_efs_file_system.efs_storage.arn}",
            "Action": [
                "elasticfilesystem:ClientMount",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:ClientRootAccess"
            ],
            "Condition": {
                "Bool": {
                    "aws:SecureTransport": "true"
                }
            }
        }
    ]
}
POLICY
}

resource "aws_efs_mount_target" "efs" {

  depends_on = [
    aws_route_table_association.subnet-association-1a, aws_security_group.task_sg, aws_efs_file_system.efs_storage
  ]

  file_system_id  = aws_efs_file_system.efs_storage.id
  subnet_id       = aws_subnet.subnet_1a.id
  security_groups = [aws_security_group.task_sg.id]
}

# Creating key
resource "tls_private_key" "private_key" {
  algorithm = "RSA"
}
# Saving to local system 
resource "local_file" "save_key" {
  depends_on = [tls_private_key.private_key]
  content    = tls_private_key.private_key.private_key_pem
  filename   = "tf_key.pem"
}
# Sending public key to aws 
resource "aws_key_pair" "public_key" {
  depends_on = [local_file.save_key]
  key_name   = "task_2_key"
  public_key = tls_private_key.private_key.public_key_openssh
}

# Creating Instance
resource "aws_instance" "ec2_task2" {
  depends_on = [
    aws_security_group.task_sg, tls_private_key.private_key
  ]
  ami                    = "ami-0732b62d310b80e97"
  instance_type          = "t2.micro"
  key_name               = "task_2_key"
  subnet_id              = aws_subnet.subnet_1a.id
  vpc_security_group_ids = [aws_security_group.task_sg.id]
  tags = {
    name = "Ec2-task-2"
  }
  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = tls_private_key.private_key.private_key_pem
    host        = aws_instance.ec2_task2.public_ip
  }
  provisioner "remote-exec" {
    inline = ["sudo yum install httpd git php amazon-efs-utils nfs-utils -y",
      "sudo systemctl restart httpd",
    "sudo systemctl enable httpd"]
  }
}

# Attaching EFS to instance
resource "null_resource" "efs_attach" {
  depends_on = [aws_efs_mount_target.efs]
  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = tls_private_key.private_key.private_key_pem
    host        = aws_instance.ec2_task2.public_ip
  }
  provisioner "remote-exec" {
    inline = ["sudo chmod ugo+rw /etc/fstab",
      "sudo echo '${aws_efs_file_system.efs_storage.id}:/ /var/www/html efs tls,_netdev' >> /etc/fstab",
      "sudo mount -a -t efs,nfs4 defaults",
      "sudo rm -rf /var/www/html/",
    "sudo git clone https://github.com/mishra5047/hybrid_cloud_1.git /var/www/html/"]
  }
}

# Creating S3 bucket 
resource "aws_s3_bucket" "task_bucket" {
  bucket        = "task-2-bucket"
  acl           = "public-read"
  force_destroy = true
  tags = {
    Name = "task-2-bucket"
  }
  versioning {
    enabled = true
  }
}

# uploading image to S3 bucket
resource "aws_s3_bucket_object" "BO_upload" {

  depends_on = [aws_s3_bucket.task_bucket]

  key           = "image.png"
  bucket        = aws_s3_bucket.task_bucket.id
  source        = "aws_image.jpg"
  etag          = "aws_image.jpg"
  force_destroy = true
  acl           = "public-read"
}

resource "aws_s3_bucket_public_access_block" "bucket_permission" {

  depends_on = [aws_s3_bucket_object.BO_upload]

  bucket              = aws_s3_bucket.task_bucket.id
  block_public_acls   = false
  block_public_policy = false
}
output "Bucket_Regional_Domain_Name" {
  value = aws_s3_bucket.task_bucket.bucket_regional_domain_name
}

# Creating CDN for S3 bucket
resource "aws_cloudfront_distribution" "bucket_distribution" {
  depends_on = [aws_s3_bucket_object.BO_upload]
  origin {
    domain_name = aws_s3_bucket.task_bucket.bucket_regional_domain_name
    origin_id   = "bucket_dist"
  }
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Image for task 2"
  default_root_object = "aws_image.png"
  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "bucket_dist"
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
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
    type        = "ssh"
    user        = "ec2-user"
    private_key = tls_private_key.private_key.private_key_pem
    host        = aws_instance.ec2_task2.public_ip
  }
  provisioner "remote-exec" {
    inline = [
      "sudo sed -i 's@URL@@g' > https://${aws_cloudfront_distribution.bucket_distribution.domain_name}/${aws_s3_bucket_object.BO_upload.key}@g' /var/www/html/index.php",
    ]
  }
}

# to lauch browser in windows with instance IP
resource "null_resource" "null2" {
  depends_on = [aws_cloudfront_distribution.bucket_distribution]

  provisioner "local-exec" {
    command = "start brave ${aws_instance.ec2_task2.public_ip}"
  }

}
