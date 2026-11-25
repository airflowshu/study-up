import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import { App } from './App'
import { loadStorageConfig } from './lib/cloud'

const root = document.getElementById('root')
if (!root) throw new Error('找不到 #root 挂载点')

// 先取存储配置再渲染：imageUrl() 在首屏就会用到，
// 晚一步会先按本站路径下发一批 <img src>，多走一次 302 才到 COS。
// 取失败也照常渲染（内部已兜成本站路径）。
void loadStorageConfig().finally(() => {
  createRoot(root).render(
    <StrictMode>
      <App />
    </StrictMode>,
  )
})
