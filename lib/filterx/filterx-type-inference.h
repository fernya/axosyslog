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
  FILTERX_STATIC_TYPE_DICT,
  FILTERX_STATIC_TYPE_LIST,
  FILTERX_STATIC_TYPE_STRING,
} FilterXStaticType;

FilterXStaticType filterx_static_type_meet(FilterXStaticType a, FilterXStaticType b);

typedef struct _FilterXTypeEnv FilterXTypeEnv;

FilterXTypeEnv *filterx_type_env_new(void);
FilterXTypeEnv *filterx_type_env_clone(const FilterXTypeEnv *self);
void filterx_type_env_free(FilterXTypeEnv *self);

FilterXStaticType filterx_type_env_get(const FilterXTypeEnv *self, FilterXVariableHandle handle);
void filterx_type_env_set(FilterXTypeEnv *self, FilterXVariableHandle handle, FilterXStaticType type);

/* Meet @src into @dst in place. For every handle present in either env, dst becomes
 * meet(dst, src). Handles present in only one env meet with UNKNOWN, yielding UNKNOWN. */
void filterx_type_env_meet_into(FilterXTypeEnv *dst, const FilterXTypeEnv *src);

struct _FilterXExpr;
void filterx_expr_infer_types(struct _FilterXExpr *self, FilterXTypeEnv *env);
void filterx_expr_infer_types_root(struct _FilterXExpr *root);

#endif
