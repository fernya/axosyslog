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

#include "filterx/filterx-type-inference.h"
#include "filterx/filterx-expr.h"

struct _FilterXTypeEnv
{
  /* key: FilterXVariableHandle via GUINT_TO_POINTER; value: FilterXStaticType via GINT_TO_POINTER.
   * Absence is equivalent to FILTERX_STATIC_TYPE_UNKNOWN, so we never store UNKNOWN entries. */
  GHashTable *handle_to_type;
};

FilterXStaticType
filterx_static_type_meet(FilterXStaticType a, FilterXStaticType b)
{
  if (a == b)
    return a;
  return FILTERX_STATIC_TYPE_UNKNOWN;
}

FilterXTypeEnv *
filterx_type_env_new(void)
{
  FilterXTypeEnv *self = g_new0(FilterXTypeEnv, 1);
  self->handle_to_type = g_hash_table_new(g_direct_hash, g_direct_equal);
  return self;
}

FilterXTypeEnv *
filterx_type_env_clone(const FilterXTypeEnv *self)
{
  FilterXTypeEnv *clone = filterx_type_env_new();
  GHashTableIter iter;
  gpointer k, v;
  g_hash_table_iter_init(&iter, self->handle_to_type);
  while (g_hash_table_iter_next(&iter, &k, &v))
    g_hash_table_insert(clone->handle_to_type, k, v);
  return clone;
}

void
filterx_type_env_free(FilterXTypeEnv *self)
{
  if (!self)
    return;
  g_hash_table_destroy(self->handle_to_type);
  g_free(self);
}

FilterXStaticType
filterx_type_env_get(const FilterXTypeEnv *self, FilterXVariableHandle handle)
{
  gpointer v = g_hash_table_lookup(self->handle_to_type, GUINT_TO_POINTER(handle));
  return (FilterXStaticType) GPOINTER_TO_INT(v);
}

void
filterx_type_env_set(FilterXTypeEnv *self, FilterXVariableHandle handle, FilterXStaticType type)
{
  if (type == FILTERX_STATIC_TYPE_UNKNOWN)
    g_hash_table_remove(self->handle_to_type, GUINT_TO_POINTER(handle));
  else
    g_hash_table_insert(self->handle_to_type, GUINT_TO_POINTER(handle), GINT_TO_POINTER((gint) type));
}

void
filterx_type_env_meet_into(FilterXTypeEnv *dst, const FilterXTypeEnv *src)
{
  /* For every handle in dst, meet with src's view (UNKNOWN if absent). Any handle in src
   * but not in dst meets with UNKNOWN -> UNKNOWN, which is the default for missing keys.
   * Net effect: dst keeps only handles that are present in both with the same type. */
  GHashTableIter iter;
  gpointer k, v;
  GPtrArray *to_drop = g_ptr_array_new();

  g_hash_table_iter_init(&iter, dst->handle_to_type);
  while (g_hash_table_iter_next(&iter, &k, &v))
    {
      gpointer sv = g_hash_table_lookup(src->handle_to_type, k);
      if (GPOINTER_TO_INT(sv) != GPOINTER_TO_INT(v))
        g_ptr_array_add(to_drop, k);
    }

  for (guint i = 0; i < to_drop->len; i++)
    g_hash_table_remove(dst->handle_to_type, g_ptr_array_index(to_drop, i));
  g_ptr_array_free(to_drop, TRUE);
}

void
filterx_expr_infer_types(FilterXExpr *self, FilterXTypeEnv *env)
{
  if (!self)
    return;

  if (self->infer_types)
    self->infer_types(self, env);
  else
    filterx_expr_infer_types_default(self, env);
}

void
filterx_expr_infer_types_root(FilterXExpr *root)
{
  if (!root)
    return;
  FilterXTypeEnv *env = filterx_type_env_new();
  filterx_expr_infer_types(root, env);
  filterx_type_env_free(env);
}
