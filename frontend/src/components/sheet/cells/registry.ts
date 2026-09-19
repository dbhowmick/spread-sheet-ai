/**
 * Column type → how its cells render (frontend-plan §7.3). Adding a type
 * (currency, select…) means one entry here plus its components. F4 adds each
 * type's `editor`.
 */
import type { Component } from 'vue'

import type { Column, ColumnType } from '@/types/contract'

import BooleanDisplay from './BooleanDisplay.vue'
import DateDisplay from './DateDisplay.vue'
import LabelDisplay from './LabelDisplay.vue'
import NumberDisplay from './NumberDisplay.vue'
import TextDisplay from './TextDisplay.vue'

export type CellAlign = 'start' | 'end' | 'center'

export interface CellTypeDef {
  display: Component
  align: CellAlign
}

export const cellTypes: Record<ColumnType, CellTypeDef> = {
  text: { display: TextDisplay, align: 'start' },
  number: { display: NumberDisplay, align: 'end' },
  boolean: { display: BooleanDisplay, align: 'center' },
  date: { display: DateDisplay, align: 'start' },
}

const labelType: CellTypeDef = { display: LabelDisplay, align: 'start' }

/** The label column always renders as a label, whatever its (text) type. */
export function cellTypeFor(column: Column): CellTypeDef {
  return column.is_label ? labelType : cellTypes[column.column_type]
}
