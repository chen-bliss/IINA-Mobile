// SPDX-License-Identifier: GPL-3.0-or-later
#include "SMBBridge.h"
#include <IINASMB2.h>
#include <stdatomic.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>

static _Thread_local int last_error_code;
static _Thread_local int last_error_stage;
static _Thread_local uint32_t last_nt_status;
int iina_smb_last_error_code(void) { return last_error_code; }
int iina_smb_last_error_stage(void) { return last_error_stage; }
uint32_t iina_smb_last_nt_status(void) { return last_nt_status; }
static int remember_error(int code, int stage) {
    last_error_code = code > 0 ? code : EIO;
    last_error_stage = stage;
    return last_error_code;
}
static int context_error(struct smb2_context *ctx) {
    uint32_t status = smb2_get_nterror(ctx);
    last_nt_status = status;
    // libsmb2 maps LOGON_FAILURE to ECONNREFUSED. Preserve the distinction
    // between a rejected SMB login and a refused TCP connection.
    int code = status == SMB2_STATUS_LOGON_FAILURE ? EACCES : (status ? nterror_to_errno(status) : EIO);
    return code > 0 ? code : EIO;
}

static struct smb2_context *connect_share(const char *server, const char *share,
                                        const char *domain, const char *username, const char *password, int *error) {
    struct smb2_context *ctx = smb2_init_context();
    last_error_code = 0; last_error_stage = 0; last_nt_status = 0;
    if (!ctx) { *error = remember_error(ENOMEM, 1); return NULL; }
    smb2_set_timeout(ctx, 15);
    smb2_set_security_mode(ctx, SMB2_NEGOTIATE_SIGNING_ENABLED);
    smb2_set_authentication(ctx, SMB2_SEC_NTLMSSP);
    smb2_set_user(ctx, username);
    smb2_set_password(ctx, password);
    if (domain[0]) smb2_set_domain(ctx, domain);
    int status = smb2_connect_share(ctx, server, share, username);
    if (status != 0) {
        int code = context_error(ctx);
        // The synchronous client returns -1 when its event loop fails; -1
        // is a generic failure here, not the errno EPERM (authentication).
        if (!last_nt_status && status < -1) code = -status;
        *error = remember_error(code, 1);
        smb2_destroy_context(ctx); return NULL;
    }
    return ctx;
}

int iina_smb_list(const char *server, const char *share, const char *path,
                  const char *domain, const char *username, const char *password,
                  void *user, iina_smb_entry_callback callback) {
    int error = 0;
    struct smb2_context *ctx = connect_share(server, share[0] ? share : "IPC$", domain, username, password, &error);
    if (!ctx) return error;
    if (!share[0]) {
        struct smb2_share_enum_reply *reply = smb2_share_enum_sync(ctx, SMB2_SHARE_INFO_1);
        if (!reply) error = remember_error(context_error(ctx), 2);
        else {
            for (uint32_t i = 0; i < reply->entries_read; i++) {
                struct smb2_share_info_1 *item = &reply->share_info.info_1[i];
                if ((item->type & 0xFFFF) == SMB2_SHARE_TYPE_DISKTREE && item->netname)
                    callback(user, item->netname, 1);
            }
            smb2_free_data(ctx, reply);
        }
    } else {
        struct smb2dir *dir = smb2_opendir(ctx, path);
        if (!dir) error = remember_error(context_error(ctx), 3);
        else {
            struct smb2dirent *item;
            while ((item = smb2_readdir(ctx, dir))) {
                if (strcmp(item->name, ".") == 0 || strcmp(item->name, "..") == 0) continue;
                callback(user, item->name, item->st.smb2_type == SMB2_TYPE_DIRECTORY);
            }
            smb2_closedir(ctx, dir);
        }
    }
    smb2_disconnect_share(ctx);
    smb2_destroy_context(ctx);
    return error;
}

struct IINASMBFile {
    struct smb2_context *ctx;
    struct smb2fh *handle;
    int64_t offset;
    int64_t length;
    uint8_t *read_buffer;
    uint32_t read_capacity;
    int64_t read_start;
    uint32_t read_count;
    uint64_t network_reads;
    atomic_bool cancelled;
};

IINASMBFile *iina_smb_open(const char *server, const char *share, const char *path,
                         const char *domain, const char *username, const char *password) {
    int error = 0;
    struct smb2_context *ctx = connect_share(server, share, domain, username, password, &error);
    if (!ctx) return NULL;
    struct smb2fh *handle = smb2_open(ctx, path, O_RDONLY);
    struct smb2_stat_64 stat;
    if (!handle) {
        remember_error(context_error(ctx), 4);
        smb2_disconnect_share(ctx); smb2_destroy_context(ctx); return NULL;
    }
    if (smb2_fstat(ctx, handle, &stat) < 0) {
        remember_error(context_error(ctx), 5);
        if (handle) smb2_close(ctx, handle);
        smb2_disconnect_share(ctx); smb2_destroy_context(ctx); return NULL;
    }
    IINASMBFile *file = calloc(1, sizeof(*file));
    if (!file) { remember_error(ENOMEM, 4); smb2_close(ctx, handle); smb2_disconnect_share(ctx); smb2_destroy_context(ctx); return NULL; }
    file->ctx = ctx; file->handle = handle; file->length = (int64_t)stat.smb2_size;
    uint32_t maximum = smb2_get_max_read_size(ctx);
    file->read_capacity = maximum && maximum < 1024 * 1024 ? maximum : 1024 * 1024;
    file->read_buffer = malloc(file->read_capacity);
    if (!file->read_buffer) {
        remember_error(ENOMEM, 4);
        smb2_close(ctx, handle); smb2_disconnect_share(ctx); smb2_destroy_context(ctx); free(file); return NULL;
    }
    atomic_init(&file->cancelled, 0);
    return file;
}
int64_t iina_smb_read(IINASMBFile *file, char *buffer, uint64_t size) {
    last_error_code = 0; last_error_stage = 0; last_nt_status = 0;
    if (!file || atomic_load(&file->cancelled)) return -1;
    if (!size) return 0;
    if (file->offset >= file->length) return 0;
    // mpv often asks for small demuxer chunks. Fetch one negotiated-size block
    // instead of paying a Wi-Fi/SMB round trip for every small read.
    if (file->offset < file->read_start || (uint64_t)(file->offset - file->read_start) >= file->read_count) {
        file->network_reads++;
        int result = smb2_pread(file->ctx, file->handle, file->read_buffer, file->read_capacity, (uint64_t)file->offset);
        if (result < 0) { remember_error(-result, 6); return -1; }
        if (!result) return 0;
        file->read_start = file->offset;
        file->read_count = (uint32_t)result;
    }
    if (atomic_load(&file->cancelled)) return -1;
    uint32_t within = (uint32_t)(file->offset - file->read_start);
    uint64_t available = file->read_count - within;
    uint64_t count = size < available ? size : available;
    memcpy(buffer, file->read_buffer + within, (size_t)count);
    file->offset += (int64_t)count;
    return (int64_t)count;
}
int64_t iina_smb_seek(IINASMBFile *file, int64_t offset) {
    if (!file || offset < 0 || atomic_load(&file->cancelled)) return -1;
    file->offset = offset;
    return offset;
}
int64_t iina_smb_size(IINASMBFile *file) { return file ? file->length : -1; }
uint64_t iina_smb_network_reads(IINASMBFile *file) { return file ? file->network_reads : 0; }
void iina_smb_cancel(IINASMBFile *file) { if (file) atomic_store(&file->cancelled, 1); }
void iina_smb_close(IINASMBFile *file) {
    if (!file) return;
    smb2_close(file->ctx, file->handle);
    smb2_disconnect_share(file->ctx);
    smb2_destroy_context(file->ctx);
    free(file->read_buffer);
    free(file);
}
