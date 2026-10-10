package com.oshinobu.app.ui.emoji

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp

/** Панель эмодзи вместо клавиатуры: все эмодзи сеткой по 10 в ряд. */
@Composable
fun EmojiPicker(onEmoji: (String) -> Unit, modifier: Modifier = Modifier) {
    LazyVerticalGrid(GridCells.Fixed(10), modifier, contentPadding = PaddingValues(8.dp)) {
        items(allEmojis) { emoji ->
            BoxWithConstraints(Modifier.aspectRatio(1f).clickable { onEmoji(emoji) }) {
                val fontSize = with(LocalDensity.current) { (maxWidth * 0.55f).toSp() }
                Text(emoji, fontSize = fontSize, modifier = Modifier.align(Alignment.Center))
            }
        }
    }
}
