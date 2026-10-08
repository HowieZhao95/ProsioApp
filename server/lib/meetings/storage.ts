import { AbortMultipartUploadCommand, CompleteMultipartUploadCommand, CreateMultipartUploadCommand,
  DeleteObjectCommand, GetObjectCommand, HeadObjectCommand, S3Client, UploadPartCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { ApiError } from "@/lib/errors";

const PART_SIZE = 8 * 1024 * 1024;
export { PART_SIZE };

function config() {
  const bucket = process.env.S3_BUCKET;
  const region = process.env.S3_REGION;
  const accessKeyId = process.env.S3_ACCESS_KEY_ID;
  const secretAccessKey = process.env.S3_SECRET_ACCESS_KEY;
  if (!bucket || !region || !accessKeyId || !secretAccessKey) {
    throw new ApiError("unavailable", "Meeting audio storage is not configured");
  }
  const endpoint = process.env.S3_ENDPOINT || undefined;
  return {
    bucket,
    client: new S3Client({ region, endpoint, forcePathStyle: !!endpoint,
      credentials: { accessKeyId, secretAccessKey } }),
  };
}

export async function beginUpload(key: string): Promise<string> {
  const { client, bucket } = config();
  const result = await client.send(new CreateMultipartUploadCommand({ Bucket: bucket, Key: key,
    ContentType: "audio/mp4" }));
  if (!result.UploadId) throw new ApiError("upstream_error", "Storage did not return an upload ID");
  return result.UploadId;
}

export async function signPart(key: string, uploadId: string, partNumber: number): Promise<string> {
  const { client, bucket } = config();
  return getSignedUrl(client, new UploadPartCommand({ Bucket: bucket, Key: key,
    UploadId: uploadId, PartNumber: partNumber }), { expiresIn: 900 });
}

export async function completeUpload(key: string, uploadId: string, parts: { ETag: string; PartNumber: number }[]) {
  const { client, bucket } = config();
  await client.send(new CompleteMultipartUploadCommand({ Bucket: bucket, Key: key,
    UploadId: uploadId, MultipartUpload: { Parts: parts } }));
}

export async function uploadedSize(key: string): Promise<number> {
  const { client, bucket } = config();
  const result = await client.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
  return result.ContentLength ?? -1;
}

export async function signedReadURL(key: string): Promise<string> {
  const { client, bucket } = config();
  return getSignedUrl(client, new GetObjectCommand({ Bucket: bucket, Key: key }), { expiresIn: 24 * 3600 });
}

export async function removeUpload(key: string, uploadId: string | null) {
  const { client, bucket } = config();
  if (uploadId) {
    try { await client.send(new AbortMultipartUploadCommand({ Bucket: bucket, Key: key, UploadId: uploadId })); }
    catch { /* Already completed or absent. */ }
  }
  try { await client.send(new DeleteObjectCommand({ Bucket: bucket, Key: key })); }
  catch { /* Cleanup can be retried by the maintenance job. */ }
}
