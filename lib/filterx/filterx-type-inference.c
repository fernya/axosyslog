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
#include "filterx/expr-variable.h"
#include "filterx/expr-getattr.h"
#include "filterx/expr-get-subscript.h"

struct _FilterXTypeEnv
{
  /* key: FilterXVariableHandle via GUINT_TO_POINTER; value: FilterXStaticTypeSpec via
   * GUINT_TO_POINTER. Absence is equivalent to all-UNKNOWN (spec == 0), so we never store
   * zero-valued entries. */
  GHashTable *handle_to_spec;
  /* Per-key attribute type tracking for one-level direct variable.key accesses.
   * key: heap-allocated "handle:attr_name" string; value: FilterXStaticTypeSpec via GUINT_TO_POINTER.
   * Tracks heterogeneous-field dicts (e.g. log.observed_time → INTEGER, log.severity_text → STRING)
   * where the container element type would smear to UNKNOWN due to mixed writes. */
  GHashTable *attr_to_spec;
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
  self->attr_to_spec = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
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

  g_hash_table_iter_init(&iter, self->attr_to_spec);
  while (g_hash_table_iter_next(&iter, &k, &v))
    g_hash_table_insert(clone->attr_to_spec, g_strdup((const gchar *) k), v);

  return clone;
}

void
filterx_type_env_free(FilterXTypeEnv *self)
{
  if (!self)
    return;
  g_hash_table_destroy(self->handle_to_spec);
  g_hash_table_destroy(self->attr_to_spec);
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

  /* Also meet attr-to-spec entries: keys only in dst get dropped (source treats them as UNKNOWN). */
  GPtrArray *attr_to_drop = g_ptr_array_new_with_free_func(g_free);
  GPtrArray *attr_to_meet_keys = g_ptr_array_new_with_free_func(g_free);
  GPtrArray *attr_to_meet_specs = g_ptr_array_new();

  g_hash_table_iter_init(&iter, dst->attr_to_spec);
  while (g_hash_table_iter_next(&iter, &k, &v))
    {
      gpointer sv = g_hash_table_lookup(src->attr_to_spec, k);
      FilterXStaticTypeSpec dst_spec = (FilterXStaticTypeSpec) GPOINTER_TO_UINT(v);
      FilterXStaticTypeSpec src_spec = (FilterXStaticTypeSpec) GPOINTER_TO_UINT(sv);
      FilterXStaticTypeSpec met = filterx_static_type_spec_meet(dst_spec, src_spec);
      if (met == 0)
        g_ptr_array_add(attr_to_drop, g_strdup((const gchar *) k));
      else if (met != dst_spec)
        {
          g_ptr_array_add(attr_to_meet_keys, g_strdup((const gchar *) k));
          g_ptr_array_add(attr_to_meet_specs, GUINT_TO_POINTER((guint) met));
        }
    }

  for (guint i = 0; i < attr_to_drop->len; i++)
    g_hash_table_remove(dst->attr_to_spec, g_ptr_array_index(attr_to_drop, i));
  for (guint i = 0; i < attr_to_meet_keys->len; i++)
    g_hash_table_insert(dst->attr_to_spec,
                        g_strdup((const gchar *) g_ptr_array_index(attr_to_meet_keys, i)),
                        g_ptr_array_index(attr_to_meet_specs, i));
  g_ptr_array_free(attr_to_drop, TRUE);
  g_ptr_array_free(attr_to_meet_keys, TRUE);
  g_ptr_array_free(attr_to_meet_specs, TRUE);
}

void
filterx_type_env_propagate_to_persistent(FilterXTypeEnv *persistent, const FilterXTypeEnv *block_env)
{
  /* Add or meet every entry from block_env into persistent.
   * Entries absent from persistent are added (new knowledge); present entries are met. */
  GHashTableIter iter;
  gpointer k, v;

  g_hash_table_iter_init(&iter, block_env->handle_to_spec);
  while (g_hash_table_iter_next(&iter, &k, &v))
    {
      FilterXStaticTypeSpec new_spec = (FilterXStaticTypeSpec) GPOINTER_TO_UINT(v);
      FilterXVariableHandle handle = (FilterXVariableHandle) GPOINTER_TO_UINT(k);
      FilterXStaticTypeSpec old_spec = filterx_type_env_get(persistent, handle);
      FilterXStaticTypeSpec merged = (old_spec == 0) ? new_spec : filterx_static_type_spec_meet(old_spec, new_spec);
      filterx_type_env_set(persistent, handle, merged);
    }

  g_hash_table_iter_init(&iter, block_env->attr_to_spec);
  while (g_hash_table_iter_next(&iter, &k, &v))
    {
      FilterXStaticTypeSpec new_spec = (FilterXStaticTypeSpec) GPOINTER_TO_UINT(v);
      FilterXStaticTypeSpec old_spec = (FilterXStaticTypeSpec) GPOINTER_TO_UINT(
                                         g_hash_table_lookup(persistent->attr_to_spec, k));
      FilterXStaticTypeSpec merged = (old_spec == 0) ? new_spec : filterx_static_type_spec_meet(old_spec, new_spec);
      if (merged != old_spec)
        g_hash_table_insert(persistent->attr_to_spec, g_strdup((const gchar *) k),
                            GUINT_TO_POINTER((guint) merged));
    }
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

void
filterx_expr_infer_types_root_persistent(FilterXExpr *root, FilterXTypeEnv *persistent_env)
{
  if (!root)
    return;
  if (!persistent_env)
    {
      filterx_expr_infer_types_root(root);
      return;
    }
  FilterXTypeEnv *env = filterx_type_env_clone(persistent_env);
  filterx_expr_infer_types(root, env);
  filterx_type_env_propagate_to_persistent(persistent_env, env);
  filterx_type_env_free(env);
}

/* Walk a getattr/get_subscript chain down to its root variable, counting the number of
 * hops. Returns FALSE if the chain does not bottom out at a trackable (non-macro) variable. */
static gboolean
_walk_to_root_variable(FilterXExpr *expr, FilterXVariableHandle *handle_out, gint *depth_out)
{
  gint depth = 0;
  while (expr)
    {
      if (filterx_variable_expr_get_handle(expr, handle_out))
        {
          *depth_out = depth;
          return TRUE;
        }
      if (filterx_expr_is_getattr(expr))
        expr = filterx_getattr_get_operand(expr);
      else if (filterx_expr_is_get_subscript(expr))
        expr = filterx_get_subscript_get_operand(expr);
      else
        return FALSE;
      depth++;
    }
  return FALSE;
}

/* Maximum getattr chain depth tracked in the attr-path map.
 * Covers chains up to variable.k0.k1.k2.k3 (4 attribute hops from the root). */
#define FILTERX_ATTR_CHAIN_MAX 4

/* Walk a purely-getattr chain to its root variable, collecting attribute names
 * top-down into keys_out[0..n_keys_out-1].  Returns FALSE for subscript hops,
 * macro variables, or chains deeper than FILTERX_ATTR_CHAIN_MAX. */
static gboolean
_collect_attr_chain(FilterXExpr *expr, FilterXVariableHandle *handle_out,
                    const gchar **keys_out, gint *n_keys_out)
{
  gint n = 0;
  while (expr)
    {
      if (filterx_variable_expr_get_handle(expr, handle_out))
        {
          /* Keys were appended bottom-up; reverse to top-down. */
          for (gint i = 0, j = n - 1; i < j; i++, j--)
            {
              const gchar *tmp = keys_out[i];
              keys_out[i] = keys_out[j];
              keys_out[j] = tmp;
            }
          *n_keys_out = n;
          return TRUE;
        }
      if (!filterx_expr_is_getattr(expr) || n >= FILTERX_ATTR_CHAIN_MAX)
        return FALSE;
      keys_out[n++] = expr->name;   /* FilterXExpr::name holds the attr key for getattr nodes */
      expr = filterx_getattr_get_operand(expr);
    }
  return FALSE;
}

/* Build the hash-table key string for a chained path.
 * Format: "handle:key0:key1:...:keyN"  (n_keys entries after the handle). */
static gchar *
_attr_chain_key(FilterXVariableHandle handle, const gchar **keys, gint n_keys)
{
  GString *s = g_string_sized_new(64);
  g_string_append_printf(s, "%u", (guint) handle);
  for (gint i = 0; i < n_keys; i++)
    {
      g_string_append_c(s, ':');
      g_string_append(s, keys[i]);
    }
  return g_string_free(s, FALSE);
}

/* Look up the type of <chain_expr>.<key> where chain_expr is a purely-getattr
 * chain rooted at a non-macro variable.  Returns UNKNOWN if the path is not
 * recorded or the chain is too deep. */
FilterXStaticTypeSpec
filterx_type_env_get_attr_for_chain(const FilterXTypeEnv *self, FilterXExpr *chain_expr,
                                    const gchar *key)
{
  const gchar *keys[FILTERX_ATTR_CHAIN_MAX + 1];
  gint n = 0;
  FilterXVariableHandle handle;

  if (!_collect_attr_chain(chain_expr, &handle, keys, &n) || n + 1 > FILTERX_ATTR_CHAIN_MAX + 1)
    return 0;

  keys[n] = key;
  gchar *k = _attr_chain_key(handle, keys, n + 1);
  gpointer v = g_hash_table_lookup(self->attr_to_spec, k);
  g_free(k);
  return filterx_static_type_sanitize((FilterXStaticTypeSpec) GPOINTER_TO_UINT(v));
}

/* Record that <chain_expr>.<key> = spec (using meet semantics for updates). */
void
filterx_type_env_meet_attr_for_chain(FilterXTypeEnv *self, FilterXExpr *chain_expr,
                                     const gchar *key, FilterXStaticTypeSpec spec)
{
  if (spec == 0)
    return;

  const gchar *keys[FILTERX_ATTR_CHAIN_MAX + 1];
  gint n = 0;
  FilterXVariableHandle handle;

  if (!_collect_attr_chain(chain_expr, &handle, keys, &n) || n + 1 > FILTERX_ATTR_CHAIN_MAX + 1)
    return;

  keys[n] = key;
  gchar *k = _attr_chain_key(handle, keys, n + 1);
  gpointer existing = g_hash_table_lookup(self->attr_to_spec, k);
  FilterXStaticTypeSpec old = (FilterXStaticTypeSpec) GPOINTER_TO_UINT(existing);
  FilterXStaticTypeSpec merged = (old == 0) ? spec : filterx_static_type_spec_meet(old, spec);
  if (merged == 0)
    {
      g_hash_table_remove(self->attr_to_spec, k);
      g_free(k);
    }
  else if (merged != old)
    g_hash_table_insert(self->attr_to_spec, k, GUINT_TO_POINTER((guint) merged));
  else
    g_free(k);
}

void
filterx_type_env_update_on_write(FilterXTypeEnv *env, FilterXExpr *container_expr,
                                 FilterXStaticTypeSpec value_spec)
{
  FilterXVariableHandle handle;
  gint depth;
  if (!_walk_to_root_variable(container_expr, &handle, &depth))
    return;

  /* The written value lands one level below the container we wrote into. */
  gint level = depth + 1;
  if (level >= FILTERX_STATIC_TYPE_MAX_DEPTH)
    return;

  FilterXStaticTypeSpec old = filterx_type_env_get(env, handle);
  if (filterx_static_type_kind(old) == FILTERX_STATIC_TYPE_UNKNOWN)
    return;

  guint shift = (guint) level * FILTERX_STATIC_TYPE_LEVEL_BITS;
  FilterXStaticType level_kind = (FilterXStaticType)((old >> shift) & FILTERX_STATIC_TYPE_LEVEL_MASK);

  FilterXStaticTypeSpec tail;
  if (level_kind == FILTERX_STATIC_TYPE_FRESH)
    tail = value_spec;                                              /* lift: commit to the written type */
  else if (level_kind == FILTERX_STATIC_TYPE_UNKNOWN)
    return;                                                         /* no committed type to refine */
  else
    tail = filterx_static_type_spec_meet(old >> shift, value_spec); /* meet with the committed type */

  FilterXStaticTypeSpec low_mask = (1u << shift) - 1; /* keep levels below @level (shift >= 8) */
  filterx_type_env_set(env, handle, (old & low_mask) | (tail << shift));
}
