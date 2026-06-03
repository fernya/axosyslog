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
  /* key: FilterXVariableHandle via GUINT_TO_POINTER; value: FilterXStaticTypeSpec via
   * GUINT_TO_POINTER. Absence is equivalent to all-UNKNOWN (spec == 0), so we never store
   * zero-valued entries. */
  GHashTable *handle_to_spec;
};

FilterXStaticTypeSpec
filterx_static_type_spec_meet(FilterXStaticTypeSpec a, FilterXStaticTypeSpec b)
{
  /* Walk levels outer→inner; once levels diverge or hit UNKNOWN, drop the rest. */
  FilterXStaticTypeSpec result = 0;
  for (gint level = 0; level < FILTERX_STATIC_TYPE_MAX_DEPTH; level++)
    {
      guint shift = level * FILTERX_STATIC_TYPE_LEVEL_BITS;
      FilterXStaticType a_lvl = (FilterXStaticType)((a >> shift) & FILTERX_STATIC_TYPE_LEVEL_MASK);
      FilterXStaticType b_lvl = (FilterXStaticType)((b >> shift) & FILTERX_STATIC_TYPE_LEVEL_MASK);
      if (a_lvl == FILTERX_STATIC_TYPE_UNKNOWN || a_lvl != b_lvl)
        break;
      result |= ((FilterXStaticTypeSpec) a_lvl) << shift;
    }
  return result;
}

FilterXTypeEnv *
filterx_type_env_new(void)
{
  FilterXTypeEnv *self = g_new0(FilterXTypeEnv, 1);
  self->handle_to_spec = g_hash_table_new(g_direct_hash, g_direct_equal);
  return self;
}

FilterXTypeEnv *
filterx_type_env_clone(const FilterXTypeEnv *self)
{
  FilterXTypeEnv *clone = filterx_type_env_new();
  GHashTableIter iter;
  gpointer k, v;
  g_hash_table_iter_init(&iter, self->handle_to_spec);
  while (g_hash_table_iter_next(&iter, &k, &v))
    g_hash_table_insert(clone->handle_to_spec, k, v);
  return clone;
}

void
filterx_type_env_free(FilterXTypeEnv *self)
{
  if (!self)
    return;
  g_hash_table_destroy(self->handle_to_spec);
  g_free(self);
}

FilterXStaticTypeSpec
filterx_type_env_get(const FilterXTypeEnv *self, FilterXVariableHandle handle)
{
  gpointer v = g_hash_table_lookup(self->handle_to_spec, GUINT_TO_POINTER(handle));
  return (FilterXStaticTypeSpec) GPOINTER_TO_UINT(v);
}

void
filterx_type_env_set(FilterXTypeEnv *self, FilterXVariableHandle handle, FilterXStaticTypeSpec spec)
{
  if (spec == 0)
    g_hash_table_remove(self->handle_to_spec, GUINT_TO_POINTER(handle));
  else
    g_hash_table_insert(self->handle_to_spec, GUINT_TO_POINTER(handle), GUINT_TO_POINTER((guint) spec));
}

void
filterx_type_env_meet_into(FilterXTypeEnv *dst, const FilterXTypeEnv *src)
{
  GHashTableIter iter;
  gpointer k, v;
  GPtrArray *to_drop = g_ptr_array_new();
  GPtrArray *to_meet_keys = g_ptr_array_new();
  GPtrArray *to_meet_specs = g_ptr_array_new();

  g_hash_table_iter_init(&iter, dst->handle_to_spec);
  while (g_hash_table_iter_next(&iter, &k, &v))
    {
      gpointer sv = g_hash_table_lookup(src->handle_to_spec, k);
      FilterXStaticTypeSpec dst_spec = (FilterXStaticTypeSpec) GPOINTER_TO_UINT(v);
      FilterXStaticTypeSpec src_spec = (FilterXStaticTypeSpec) GPOINTER_TO_UINT(sv);
      FilterXStaticTypeSpec met = filterx_static_type_spec_meet(dst_spec, src_spec);
      if (met == 0)
        g_ptr_array_add(to_drop, k);
      else if (met != dst_spec)
        {
          g_ptr_array_add(to_meet_keys, k);
          g_ptr_array_add(to_meet_specs, GUINT_TO_POINTER((guint) met));
        }
    }

  for (guint i = 0; i < to_drop->len; i++)
    g_hash_table_remove(dst->handle_to_spec, g_ptr_array_index(to_drop, i));
  for (guint i = 0; i < to_meet_keys->len; i++)
    g_hash_table_insert(dst->handle_to_spec, g_ptr_array_index(to_meet_keys, i),
                        g_ptr_array_index(to_meet_specs, i));
  g_ptr_array_free(to_drop, TRUE);
  g_ptr_array_free(to_meet_keys, TRUE);
  g_ptr_array_free(to_meet_specs, TRUE);
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
