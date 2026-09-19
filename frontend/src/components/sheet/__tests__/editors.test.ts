import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import CellEditor from '@/components/sheet/cells/CellEditor.vue'
import DateEditor from '@/components/sheet/cells/DateEditor.vue'
import { MOVE_DOWN, MOVE_LEFT, MOVE_RIGHT } from '@/lib/sheet/navigation'
import type { CellValue, Column } from '@/types/contract'

const text: Column = { id: 'c-note', name: 'Note', column_type: 'text', is_label: false }
const number: Column = { id: 'c-amt', name: 'Amount', column_type: 'number', is_label: false }
const label: Column = { id: 'c-label', name: 'Line item', column_type: 'text', is_label: true }
const date: Column = { id: 'c-due', name: 'Due', column_type: 'date', is_label: false }

interface Options {
  initialInput?: string | null
  error?: string | null
}

function mountEditor(column: Column, value: CellValue, options: Options = {}) {
  return mount(CellEditor, {
    props: {
      column,
      value,
      initialInput: options.initialInput ?? null,
      error: options.error ?? null,
    },
  })
}

describe('starting text', () => {
  it('opens on the cell’s current value', () => {
    expect(mountEditor(text, 'Hello').get('input').element.value).toBe('Hello')
  })

  it('is empty for an empty cell', () => {
    expect(mountEditor(text, null).get('input').element.value).toBe('')
  })

  it('shows a date as ISO, so it round-trips', () => {
    expect(mountEditor(date, '2026-03-01').get('input').element.value).toBe('2026-03-01')
  })

  it('shows a number unlocalized, so it parses back', () => {
    expect(mountEditor(number, 1200).get('input').element.value).toBe('1200')
  })

  it('starts from the typed character when the edit began by typing (§7.4)', () => {
    expect(mountEditor(number, 999, { initialInput: '4' }).get('input').element.value).toBe('4')
  })
})

describe('committing', () => {
  it('commits the raw text and moves down on Enter', async () => {
    const editor = mountEditor(text, 'old')
    await editor.get('input').setValue('new')
    await editor.get('input').trigger('keydown', { key: 'Enter' })

    expect(editor.emitted('commit')).toEqual([['new', MOVE_DOWN]])
  })

  it('moves right on Tab and left on Shift+Tab', async () => {
    const forward = mountEditor(text, 'a')
    await forward.get('input').trigger('keydown', { key: 'Tab' })
    expect(forward.emitted('commit')?.[0]?.[1]).toEqual(MOVE_RIGHT)

    const back = mountEditor(text, 'a')
    await back.get('input').trigger('keydown', { key: 'Tab', shiftKey: true })
    expect(back.emitted('commit')?.[0]?.[1]).toEqual(MOVE_LEFT)
  })

  it('sends the text untouched — parsing happens in one place, on commit', async () => {
    const editor = mountEditor(number, null)
    await editor.get('input').setValue('1,200')
    await editor.get('input').trigger('keydown', { key: 'Enter' })

    expect(editor.emitted('commit')?.[0]?.[0]).toBe('1,200')
  })

  it('cancels on Escape without committing', async () => {
    const editor = mountEditor(text, 'a')
    await editor.get('input').trigger('keydown', { key: 'Escape' })

    expect(editor.emitted('cancel')).toHaveLength(1)
    expect(editor.emitted('commit')).toBeUndefined()
  })

  it('leaves the arrows to the caret', async () => {
    const editor = mountEditor(text, 'a')
    await editor.get('input').trigger('keydown', { key: 'ArrowLeft' })

    expect(editor.emitted('commit')).toBeUndefined()
    expect(editor.emitted('cancel')).toBeUndefined()
  })
})

describe('a rejected value', () => {
  it('shows the message and stays open with the text (§7.3)', async () => {
    const editor = mountEditor(number, null, { error: '"abc" is not a number.' })

    expect(editor.get('[role="alert"]').text()).toBe('"abc" is not a number.')
    expect(editor.get('input').attributes('aria-invalid')).toBe('true')
    expect(editor.find('input').exists()).toBe(true)
  })

  it('is absent while the value is fine', () => {
    const editor = mountEditor(number, 12)
    expect(editor.find('[role="alert"]').exists()).toBe(false)
  })
})

describe('per-type affordances', () => {
  it('gives numbers a numeric keypad and end alignment', () => {
    const input = mountEditor(number, 1).get('input')
    expect(input.attributes('inputmode')).toBe('decimal')
    expect(input.classes()).toContain('text-end')
  })

  it('edits the row label with the same input', () => {
    // Uniqueness is checked on commit, where the whole sheet is in scope.
    expect(mountEditor(label, 'Revenue').get('input').element.value).toBe('Revenue')
  })

  it('gives a date a picker beside the typed input', () => {
    const editor = mount(DateEditor, {
      props: { column: date, value: '2026-03-01', initialInput: null, error: null },
    })
    expect(editor.get('input').element.value).toBe('2026-03-01')
    expect(editor.find('[aria-label="Pick a date"]').exists()).toBe(true)
  })

  it('passes a date’s keys through the shared editor', async () => {
    const editor = mount(DateEditor, {
      props: { column: date, value: null, initialInput: '2', error: null },
    })
    await editor.get('input').setValue('2026-12-25')
    await editor.get('input').trigger('keydown', { key: 'Enter' })

    expect(editor.emitted('commit')).toEqual([['2026-12-25', MOVE_DOWN]])
  })
})
