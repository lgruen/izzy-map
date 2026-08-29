// Temporary multipart uploader for archives >300 MiB (wrangler's direct
// upload cap). Deployed with a fresh random secret per run by upload_r2.sh,
// then DELETED — never left standing. R2 multipart parts must be >=5 MiB
// (except the last); the driver uses 64 MiB parts to stay under the Workers
// request body limit.
export default {
  async fetch(req, env) {
    if (req.headers.get("x-auth") !== env.UPLOAD_SECRET)
      return new Response("forbidden", { status: 403 });
    const url = new URL(req.url);
    const key = url.searchParams.get("key");
    const action = url.searchParams.get("action");
    if (!key) return new Response("missing key", { status: 400 });

    if (action === "create") {
      const mpu = await env.BUCKET.createMultipartUpload(key);
      return Response.json({ uploadId: mpu.uploadId });
    }
    if (action === "part") {
      const mpu = env.BUCKET.resumeMultipartUpload(key, url.searchParams.get("uploadId"));
      const n = Number(url.searchParams.get("part"));
      const part = await mpu.uploadPart(n, req.body);
      return Response.json({ partNumber: part.partNumber, etag: part.etag });
    }
    if (action === "complete") {
      const mpu = env.BUCKET.resumeMultipartUpload(key, url.searchParams.get("uploadId"));
      const parts = await req.json();
      await mpu.complete(parts);
      return Response.json({ ok: true });
    }
    if (action === "put") {
      // small files (< ~90 MiB) in one go
      await env.BUCKET.put(key, req.body);
      return Response.json({ ok: true });
    }
    return new Response("bad action", { status: 400 });
  },
};
