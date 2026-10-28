// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stddef.h>
#include <stdint.h>
typedef void (*iina_smb_entry_callback)(void *user, const char *name, int directory);
int iina_smb_list(const char *server, const char *share, const char *path, const char *domain, const char *username,
                  const char *password, void *user, iina_smb_entry_callback callback);
typedef struct IINASMBFile IINASMBFile;
IINASMBFile *iina_smb_open(const char *server, const char *share, const char *path,
                         const char *domain, const char *username, const char *password);
int64_t iina_smb_read(IINASMBFile *file, char *buffer, uint64_t size);
int64_t iina_smb_seek(IINASMBFile *file, int64_t offset);
int64_t iina_smb_size(IINASMBFile *file);
uint64_t iina_smb_network_reads(IINASMBFile *file);
void iina_smb_cancel(IINASMBFile *file);
void iina_smb_close(IINASMBFile *file);
// Thread-local, password-free diagnostic for the most recent operation on this thread.
int iina_smb_last_error_code(void);
int iina_smb_last_error_stage(void);
uint32_t iina_smb_last_nt_status(void);
