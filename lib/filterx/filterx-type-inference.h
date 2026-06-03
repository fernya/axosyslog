/*
 * Copyright (c) 2026 Axoflow
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * As an additional exemption you are allowed to compile & link against the
 * OpenSSL libraries as published by the OpenSSL project. See the file
 * COPYING for details.
 *
 */
#ifndef FILTERX_TYPE_INFERENCE_H_INCLUDED
#define FILTERX_TYPE_INFERENCE_H_INCLUDED

#include "syslog-ng.h"
#include "filterx/filterx-variable.h"

typedef enum
{
  FILTERX_STATIC_TYPE_UNKNOWN = 0,
  FILTERX_STATIC_TYPE_DICT    = 1,
  FILTERX_STATIC_TYPE_LIST    = 2,
  FILTERX_STATIC_TYPE_STRING  = 3,
} FilterXStaticType;

/* FilterXStaticTypeSpec: a packed nested type spec, one byte per nesting level.
 *
 *   level 0 (LSB)  — the outer type of the expression
 *   level 1         — the element type of a DICT/LIST at level 0 (the spec's "shift")
 *   level 2         — element type of level 1
 *   level 3         — element type of level 2
 *
 * UNKNOWN at any level implies UNKNOWN at all deeper levels (we never carry useful
 * info "below" an unknown). STRING / UNKNOWN at level i has all deeper levels as
 * UNKNOWN since they don't have elements.
 *
 * Packed as guint32 so it copies and compares cheaply, fits in an env hash table
 * slot via GINT_TO_POINTER, and the all-zero pattern is exactly the UNKNOWN spec.
 */
typedef guint32 FilterXStaticTypeSpec;

#define FILTERX_STATIC_TYPE_MAX_DEPTH 4
#define FILTERX_STATIC_TYPE_LEVEL_BITS 8
#define FILTERX_STATIC_TYPE_LEVEL_MASK 0xffU

static inline FilterXStaticType
filterx_static_type_kind(FilterXStaticTypeSpec spec)
{
  return (FilterXStaticType)(spec & FILTERX_STATIC_TYPE_LEVEL_MASK);
}

/* Drop the outermost level: returns the element type spec.
 * Element of {DICT, STRING, UNKNOWN, UNKNOWN} → {STRING, UNKNOWN, UNKNOWN, UNKNOWN}.
 * Element of {STRING, ...} or {UNKNOWN, ...} → all-UNKNOWN. */
static inline FilterXStaticTypeSpec
filterx_static_type_element(FilterXStaticTypeSpec spec)
{
  FilterXStaticType kind = filterx_static_type_kind(spec);
  if (kind != FILTERX_STATIC_TYPE_DICT && kind != FILTERX_STATIC_TYPE_LIST)
    return 0;
  return spec >> FILTERX_STATIC_TYPE_LEVEL_BITS;
}

/* Build a container spec from an outer kind and the element spec. Shifts @element up
 * by one level; the deepest byte of @element falls off (depth-4 truncation). */
static inline FilterXStaticTypeSpec
filterx_static_type_make_container(FilterXStaticType kind, FilterXStaticTypeSpec element)
{
  return ((FilterXStaticTypeSpec) kind) | (element << FILTERX_STATIC_TYPE_LEVEL_BITS);
}

/* Per-level meet. Walks outer→inner; once the levels diverge or hit UNKNOWN, all
 * deeper levels are cleared. */
FilterXStaticTypeSpec filterx_static_type_spec_meet(FilterXStaticTypeSpec a, FilterXStaticTypeSpec b);

/* Convenience for the common case where we just need the outer-kind meet (no
 * element info). Returns kind only; deeper levels of the result are UNKNOWN. */
static inline FilterXStaticTypeSpec
filterx_static_type_kind_only(FilterXStaticType kind)
{
  return (FilterXStaticTypeSpec) kind;
}

typedef struct _FilterXTypeEnv FilterXTypeEnv;

FilterXTypeEnv *filterx_type_env_new(void);
FilterXTypeEnv *filterx_type_env_clone(const FilterXTypeEnv *self);
void filterx_type_env_free(FilterXTypeEnv *self);

FilterXStaticTypeSpec filterx_type_env_get(const FilterXTypeEnv *self, FilterXVariableHandle handle);
void filterx_type_env_set(FilterXTypeEnv *self, FilterXVariableHandle handle, FilterXStaticTypeSpec spec);

/* Meet @src into @dst in place. Handles only in one env meet with all-UNKNOWN
 * → all-UNKNOWN (which is the absent-key default). */
void filterx_type_env_meet_into(FilterXTypeEnv *dst, const FilterXTypeEnv *src);

struct _FilterXExpr;
void filterx_expr_infer_types(struct _FilterXExpr *self, FilterXTypeEnv *env);
void filterx_expr_infer_types_root(struct _FilterXExpr *root);

#endif
