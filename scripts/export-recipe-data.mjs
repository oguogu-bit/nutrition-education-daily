#!/usr/bin/env node
/**
 * export-recipe-data.mjs
 * 献立アプリの recipes.ts から JSON を生成する
 * 実行: node scripts/export-recipe-data.mjs
 */

import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import vm from 'vm';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_DIR = join(__dirname, '..');
const RECIPES_TS = '/Users/ogu/Desktop/Claude code/献立/src/data/recipes.ts';
const OUTPUT_JSON = join(REPO_DIR, 'data', 'recipes-snapshot.json');

// recipes.ts を読み込んで TypeScript 固有の構文を除去
let source = readFileSync(RECIPES_TS, 'utf-8');

// RECIPES 配列の部分だけを抽出する
// 1行目の import type を除去
// export const RECIPES: Recipe[] = [...] の部分だけ残す
// 末尾のヘルパー関数（export function）を除去

// import type 行を除去
source = source.replace(/^import type.*;\n?/m, '');

// export const RECIPES: Recipe[] = を const RECIPES = に変換
source = source.replace(/^export const RECIPES: Recipe\[\] =/m, 'const RECIPES =');

// export function ... { ... } ブロックを除去（複数行）
// 末尾のコメント行 + export function ブロックをまとめて除去
source = source.replace(/\/\/ .+\nexport function[\s\S]*$/m, '');

// 最後に RECIPES を返す式を追加
source = source.trimEnd() + '\nRECIPES';

// vm で安全に評価
const context = {};
vm.createContext(context);
let recipes;
try {
  recipes = vm.runInNewContext(source, context);
} catch (e) {
  console.error('recipes.ts のパースに失敗しました:', e.message);
  process.exit(1);
}

if (!Array.isArray(recipes) || recipes.length === 0) {
  console.error('レシピデータが空です');
  process.exit(1);
}

// data/ ディレクトリを作成
mkdirSync(join(REPO_DIR, 'data'), { recursive: true });

// JSON として出力
writeFileSync(OUTPUT_JSON, JSON.stringify(recipes, null, 2), 'utf-8');
console.log(`${recipes.length} 件のレシピを ${OUTPUT_JSON} に出力しました`);
