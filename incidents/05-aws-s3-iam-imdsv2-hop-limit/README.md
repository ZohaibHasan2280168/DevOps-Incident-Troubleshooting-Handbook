# 🚨 INC-005: AWS S3 403 Forbidden & IMDSv2 Metadata Hop Limit in Docker

| Metadata | Details |
| :--- | :--- |
| **Incident ID** | INC-005 |
| **Severity** | P1 (Storage Ingestion Failure / Access Denied) |
| **Subsystems** | AWS S3, IAM Instance Profile, EC2 IMDSv2, Docker Bridge Network, Boto3 |
| **Target Infrastructure** | EC2 Instance `i-038112618ff09da48` / S3 Bucket `smartdoc-storage-zohaib-2026` |
| **Branch Reference** | `incident-05/aws-s3-iam-imdsv2-hop-limit` |
| **Resolution Status** | 🟢 Resolved |

---

## 1. 🔍 Incident Summary & Symptoms

During production testing of the `smartdoc-ai` document ingestion workflow on an AWS EC2 instance, the FastAPI backend failed to persist uploaded files to the target Amazon S3 bucket (`smartdoc-storage-zohaib-2026`).

Application logs within the Docker container reported persistent 403 client errors:

```log
ERROR:   [FastAPI] Document ingestion dispatch failed.
ERROR:   botocore.exceptions.ClientError: An error occurred (403) when calling the PutObject operation: Access Denied
WARNING: [StorageFallback] Amazon S3 upload failed (403 Forbidden). Persisting to temporary local container disk /tmp/.
```

### The Diagnostic Paradox:
When diagnosing directly on the EC2 host shell, AWS CLI commands succeeded without issue:
```bash
$ aws s3 ls s3://smartdoc-storage-zohaib-2026/
2026-10-07 14:10:00  init.txt
```
However, the exact same AWS SDK call made from **inside the Docker container** failed with `403 Forbidden` or `NoCredentialsError: Unable to locate credentials`.

---

## 2. 🧠 Root Cause Analysis (RCA)

This incident stems from two compounding factors: **Identity Architecture** and **Network Packet Time-To-Live (TTL) boundaries in Linux Bridge Namespaces**.

### Factor A: Static Credentials Anti-Pattern vs IAM Instance Profile
A common insecure anti-pattern is generating long-term IAM User Access Keys (`AWS_ACCESS_KEY_ID` & `AWS_SECRET_ACCESS_KEY`) and embedding them into container environment variables. This creates severe compliance vulnerabilities:
* Exposed secrets via `docker inspect` and runtime memory dumps.
* High maintenance overhead for credential rotation.
* High security blast-radius if leaked.

The enterprise cloud solution is **Keyless Authentication** using an **IAM Instance Profile** attached to the EC2 host. The AWS SDK (Boto3) automatically queries the **Instance Metadata Service (IMDS)** at link-local IP `169.254.169.254` to fetch rotating, temporary STS tokens.

### Factor B: The IMDSv2 Docker Bridge Hop Limit Trap
Under AWS EC2's hardened **IMDSv2** (Instance Metadata Service Version 2):
1. All metadata sessions require a secure `PUT` request with a token header (`X-aws-ec2-metadata-token`).
2. To protect against Server-Side Request Forgery (SSRF) vulnerabilities and open proxy leaks, AWS enforces a default **Network Hop Limit (TTL) = 1** on the metadata service response.
3. When a request originates from **inside a Docker container** on a user-defined bridge network (`smartdoc-net`), the network packet travels from the container namespace through the virtual Ethernet bridge (`docker0` / `br-xxx`) before reaching the EC2 host network interface:
   $$\text{Hop 1: Container} \longrightarrow \text{Host Bridge Gateway} \quad (\text{TTL decremented by 1})$$
4. By the time the response packet attempts to route back across the bridge interface into the container namespace, its **TTL has dropped to 0**! The kernel drops the packet immediately.
5. Consequently, the Python Boto3 SDK inside the container never receives the STS authentication token and defaults to unauthenticated/denied requests (`403 Access Denied`).

```
+-----------------------------------------------------------------------------------------+
| AWS EC2 Instance (i-038112618ff09da48)                                                   |
|                                                                                         |
|  [ smartdoc-backend Container ]                                                         |
|    |                                                                                    |
|    | Query: http://169.254.169.254/latest/api/token (IMDSv2)                            |
|    v                                                                                    |
|  [ Docker Bridge: smartdoc-net ] ---> (Hop 1: Packet TTL decremented from 1 to 0!)      |
|    |                                                                                    |
|    x ---> Packet TTL Expired! Container receives NO Token! 💥                          |
|                                                                                         |
|  [ IMDSv2 Metadata Service: 169.254.169.254 ] (Default Hop Limit = 1)                   |
+-----------------------------------------------------------------------------------------+
```

---

## 3. 🛠️ The Production Fix & Remediation Runbook

### Step 1: Inspect Current EC2 Metadata Configuration
Query the instance metadata settings using the AWS CLI:

```bash
aws ec2 describe-instances \
  --instance-ids i-038112618ff09da48 \
  --query "Reservations[0].Instances[0].MetadataOptions" \
  --output json
```

**Observed Configuration:**
```json
{
  "State": "applied",
  "HttpTokens": "required",
  "HttpPutResponseHopLimit": 1,
  "HttpEndpoint": "enabled"
}
```
Notice `HttpPutResponseHopLimit: 1` — this is what causes container packet drops.

---

### Step 2: Elevate IMDSv2 Hop Limit to 2
Modify the instance metadata options to allow packets to traverse the Docker bridge network router:

```bash
aws ec2 modify-instance-metadata-options \
  --instance-id i-038112618ff09da48 \
  --http-put-response-hop-limit 2 \
  --http-endpoint enabled
```

* Setting `http-put-response-hop-limit 2` permits exactly one additional network hop, enabling containers attached to local Docker bridge networks to communicate with IMDSv2 while preserving SSRF protection against multi-hop traversal.

---

### Step 3: Attach Least-Privilege IAM Policy to Instance Profile
Ensure the IAM Role attached to the EC2 instance strictly permits required S3 operations on the bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SmartDocS3BucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::smartdoc-storage-zohaib-2026"
    },
    {
      "Sid": "SmartDocS3ObjectAccess",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::smartdoc-storage-zohaib-2026/*"
    }
  ]
}
```

---

## 4. 🧪 Automated Verification & Container Testing

### 1. Test IMDS Token Retrieval from Inside Container
Execute a test query directly from within the `smartdoc-backend` container:

```bash
docker exec -it smartdoc-backend sh -c '
  TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/
'
```
**Expected Output:**
```
SmartDoc-EC2-S3-Role
```
*(Confirms container successfully retrieved the IAM role identity from IMDSv2!)*

### 2. Verify Live Document Upload to S3
Trigger a test document ingestion and verify storage persistence:

```bash
docker exec -it smartdoc-backend python -c '
import boto3
s3 = boto3.client("s3", region_name="us-east-1")
s3.put_object(Bucket="smartdoc-storage-zohaib-2026", Key="test-verification.txt", Body=b"IMDSv2 Hop Limit 2 Verification Success")
print(">>> S3 PutObject SUCCESS: Keyless authentication verified!")
'
```

---

## 5. 🛡️ Prevention & Production Best Practices

1. **Deterministic Terraform Provisioning**: Always declare `http_put_response_hop_limit = 2` when provisioning container hosts in Terraform:
   ```hcl
   resource "aws_instance" "app_server" {
     ami           = "ami-0c7217cdde317cfec"
     instance_type = "t3.small"
     iam_instance_profile = aws_iam_instance_profile.ec2_s3_profile.name

     metadata_options {
       http_endpoint               = "enabled"
       http_tokens                 = "required" # Enforce IMDSv2
       http_put_response_hop_limit = 2          # Essential for Docker bridge
     }
   }
   ```
2. **Never Store Long-Term Access Keys**: Run security linters like `trufflehog` or `git-secrets` in pre-commit hooks to block static AWS keys from reaching git repositories.
3. **S3 Bucket Encryption & Block Public Access**: Maintain default server-side encryption (`AES256` or AWS KMS) and enforce S3 Block Public Access on all ingestion buckets.
