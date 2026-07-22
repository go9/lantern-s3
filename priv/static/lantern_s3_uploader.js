// Lantern — client-side glue for the bucket viewer LiveComponent.
//
// Two exports:
//   * `S3` — a LiveView external uploader. The server's `presign_upload/2`
//     returns `meta: %{uploader: "S3", url: presigned_put_url, key: ...}`;
//     LiveView dispatches the entry here, and we PUT the file straight to the
//     object store, reporting progress back to the LiveComponent.
//   * `LanternS3Download` — a hook (mounted on the component root) that turns a
//     `lantern:download` push_event into real browser downloads, for single
//     files (`{url, name}`) or a batch (`{items: [{url, name}, ...]}`).

export const S3 = (entries, onViewError) => {
  entries.forEach((entry) => {
    const { url } = entry.meta

    const xhr = new XMLHttpRequest()
    onViewError(() => xhr.abort())

    xhr.onload = () =>
      xhr.status >= 200 && xhr.status < 300 ? entry.progress(100) : entry.error()
    xhr.onerror = () => entry.error()

    xhr.upload.addEventListener("progress", (event) => {
      if (event.lengthComputable) {
        const percent = Math.round((event.loaded / event.total) * 100)
        // Never report 100 from progress; let onload mark completion so the
        // entry isn't consumed before the PUT actually finishes.
        if (percent < 100) entry.progress(percent)
      }
    })

    xhr.open("PUT", url, true)
    if (entry.file.type) xhr.setRequestHeader("Content-Type", entry.file.type)
    xhr.send(entry.file)
  })
}

const triggerDownload = ({ url, name }) => {
  const a = document.createElement("a")
  a.href = url
  if (name) a.download = name
  a.rel = "noopener"
  // Same-origin downloads honor `download`; cross-origin presigned URLs ignore
  // it and open/download per the Content-Disposition the store returns.
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
}

export const LanternS3Download = {
  mounted() {
    this.handleEvent("lantern:download", (payload) => {
      if (Array.isArray(payload.items)) {
        payload.items.forEach((item, i) => {
          const spec = typeof item === "string" ? { url: item } : item
          // Stagger batch downloads so the browser doesn't drop concurrent ones.
          setTimeout(() => triggerDownload(spec), i * 300)
        })
      } else if (payload.url) {
        triggerDownload(payload)
      }
    })
  },
}
