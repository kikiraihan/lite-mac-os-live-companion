// Klien API. Dua "pintu" yang sengaja terpisah: pengguna (/api/…) dan admin (/api/admin/…) —
// masing-masing punya cookie sesi & token CSRF sendiri di server.

function makeClient(prefix) {
  let csrf = ''
  async function call(path, { method = 'GET', body, form } = {}) {
    const headers = {}
    if (csrf) headers['X-CSRF-Token'] = csrf
    let payload
    if (form) payload = form
    else if (body !== undefined) { headers['Content-Type'] = 'application/json'; payload = JSON.stringify(body) }
    let res
    try {
      res = await fetch(prefix + path, { method, headers, body: payload, credentials: 'same-origin' })
    } catch {
      throw new ApiError(0, 'offline', 'Tidak bisa menghubungi server. Periksa koneksi internetmu.')
    }
    const data = await res.json().catch(() => ({}))
    if (data.csrf_token) csrf = data.csrf_token
    if (!res.ok) {
      throw new ApiError(res.status, data.error?.code || 'error', data.error?.message || 'Ada masalah di server. Coba lagi sebentar.')
    }
    return data
  }
  return {
    get: (p) => call(p),
    post: (p, body) => call(p, { method: 'POST', body: body ?? {} }),
    patch: (p, body) => call(p, { method: 'PATCH', body }),
    put: (p, body) => call(p, { method: 'PUT', body }),
    del: (p) => call(p, { method: 'DELETE' }),
    upload: (p, form) => call(p, { method: 'POST', form }),
  }
}

export class ApiError extends Error {
  constructor(status, code, message) {
    super(message)
    this.status = status
    this.code = code
  }
}

export const api = makeClient('/api')
export const adminApi = makeClient('/api/admin')
