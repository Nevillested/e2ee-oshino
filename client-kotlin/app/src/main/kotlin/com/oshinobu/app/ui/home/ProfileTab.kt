package com.oshinobu.app.ui.home

import com.oshinobu.app.ui.AppLoadingIndicator
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Badge
import androidx.compose.material.icons.outlined.Cake
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.oshinobu.app.R
import com.oshinobu.app.app
import com.oshinobu.app.ui.AvatarImage
import com.oshinobu.app.ui.ErrorRed
import com.oshinobu.app.ui.FullScreenLoading
import com.oshinobu.app.ui.PhotoViewerDialog
import com.oshinobu.app.ui.theme.LocalAppColors
import com.oshinobu.core.service.retryUntilSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

/** Аватар: не больше 512×512, JPEG 85% — как делал Flutter-клиент (image_picker). */
private suspend fun Context.loadAvatarJpeg(uri: Uri): ByteArray = withContext(Dispatchers.IO) {
    val source = if (Build.VERSION.SDK_INT >= 28) {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(contentResolver, uri)) { decoder, info, _ ->
            val longest = maxOf(info.size.width, info.size.height)
            if (longest > 512) decoder.setTargetSize(info.size.width * 512 / longest, info.size.height * 512 / longest)
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
    } else {
        @Suppress("DEPRECATION")
        MediaStore.Images.Media.getBitmap(contentResolver, uri).let { full ->
            val longest = maxOf(full.width, full.height)
            if (longest > 512) Bitmap.createScaledBitmap(full, full.width * 512 / longest, full.height * 512 / longest, true) else full
        }
    }
    ByteArrayOutputStream().also { source.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
}

private enum class ProfileEdit { DISPLAY_NAME, STATUS, BIRTHDAY }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileTab() {
    val context = LocalContext.current
    val core = context.app.core
    val colors = LocalAppColors.current
    val scope = rememberCoroutineScope()
    val profile by core.myAccount.profile.collectAsState()
    val avatar by core.myAccount.avatar.collectAsState()
    var uploading by remember { mutableStateOf(false) }
    var avatarSheet by remember { mutableStateOf(false) }
    var viewing by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<ProfileEdit?>(null) }
    val failed = stringResource(R.string.settings_avatarUploadFailed)

    /** Загрузка/удаление аватара; null — удалить. */
    fun changeAvatar(bytes: ByteArray?) {
        val token = core.session.token ?: return
        uploading = true
        scope.launch {
            try {
                if (bytes != null) core.api.uploadAvatar(token, bytes) else core.api.deleteAvatar(token)
                core.myAccount.setAvatar(bytes)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                Toast.makeText(context, failed, Toast.LENGTH_SHORT).show()
            } finally {
                uploading = false
            }
        }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) scope.launch { changeAvatar(context.loadAvatarJpeg(uri)) }
    }
    fun pick() = picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))

    val p = profile
    if (p == null) {
        FullScreenLoading()
        return
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val diameter = maxWidth * 0.4f
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = 16.dp, bottom = HomeTabsReserve)) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                Box(
                    Modifier.size(diameter).clickable(enabled = !uploading) { if (avatar == null) pick() else avatarSheet = true },
                    contentAlignment = Alignment.Center,
                ) {
                    if (uploading) AppLoadingIndicator(size = 32.dp, color = colors.primary) else AvatarImage(avatar, diameter)
                }
            }
            Spacer(Modifier.height(24.dp))
            ProfileRow(Icons.Outlined.Badge, stringResource(R.string.profile_login), p.login)
            ProfileRow(
                Icons.Outlined.Badge, stringResource(R.string.profile_displayName),
                p.displayName?.takeIf { it.isNotEmpty() } ?: stringResource(R.string.profile_displayNameEmpty),
            ) { editing = ProfileEdit.DISPLAY_NAME }
            ProfileRow(
                Icons.Outlined.ChatBubbleOutline, stringResource(R.string.profile_status),
                p.status?.takeIf { it.isNotEmpty() } ?: stringResource(R.string.profile_statusEmpty),
            ) { editing = ProfileEdit.STATUS }
            ProfileRow(Icons.Outlined.Cake, stringResource(R.string.profile_birthday), p.birthday ?: stringResource(R.string.profile_birthdayEmpty)) {
                editing = ProfileEdit.BIRTHDAY
            }
        }
    }

    if (avatarSheet) {
        ModalBottomSheet(onDismissRequest = { avatarSheet = false }, containerColor = colors.surface) {
            SheetAction(Icons.Outlined.Visibility, stringResource(R.string.settings_avatarView), colors.primary) {
                avatarSheet = false
                viewing = true
            }
            SheetAction(Icons.Outlined.PhotoCamera, stringResource(R.string.settings_avatarChange), colors.primary) {
                avatarSheet = false
                pick()
            }
            SheetAction(Icons.Outlined.Delete, stringResource(R.string.settings_avatarRemove), ErrorRed) {
                avatarSheet = false
                changeAvatar(null)
            }
            Spacer(Modifier.height(24.dp))
        }
    }
    if (viewing) avatar?.let { PhotoViewerDialog(it) { viewing = false } }

    /** Сохранение поля профиля: повторы до успеха (как во Flutter), потом — в локальную копию. */
    fun save(update: suspend (String) -> Unit, apply: () -> Unit) {
        val token = core.session.token ?: return
        core.scope.launch {
            retryUntilSuccess { update(token) }
            apply()
        }
    }
    when (editing) {
        ProfileEdit.DISPLAY_NAME -> TextEditDialog(
            title = stringResource(R.string.profile_editDisplayName),
            hint = stringResource(R.string.profile_displayNameHint),
            initial = p.displayName ?: "",
            maxLength = 50,
            onDismiss = { editing = null },
        ) { name ->
            editing = null
            save({ core.api.updateDisplayName(it, name) }) { core.myAccount.setDisplayName(name) }
        }
        ProfileEdit.STATUS -> TextEditDialog(
            title = stringResource(R.string.profile_editStatus),
            hint = stringResource(R.string.profile_statusHint),
            initial = p.status ?: "",
            maxLength = 200,
            singleLine = false,
            onDismiss = { editing = null },
        ) { status ->
            editing = null
            save({ core.api.updateStatus(it, status) }) { core.myAccount.setStatus(status) }
        }
        ProfileEdit.BIRTHDAY -> BirthdayPicker(p.birthday, onDismiss = { editing = null }) { date ->
            editing = null
            save({ core.api.updateBirthday(it, date) }) { core.myAccount.setBirthday(date) }
        }
        null -> Unit
    }
}

/** Строка профиля: иконка, подпись, значение; [onEdit] — карандаш и тап. */
@Composable
fun ProfileRow(icon: ImageVector, title: String, value: String, onEdit: (() -> Unit)? = null) {
    val colors = LocalAppColors.current
    Row(
        Modifier.fillMaxWidth().then(if (onEdit != null) Modifier.clickable(onClick = onEdit) else Modifier).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = colors.textMuted)
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = colors.textPrimary)
            Text(value, color = colors.textMuted)
        }
        if (onEdit != null) Icon(Icons.Outlined.Edit, null, tint = colors.textMuted)
    }
}

@Composable
private fun SheetAction(icon: ImageVector, text: String, tint: Color, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 20.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = tint)
        Spacer(Modifier.width(16.dp))
        Text(text, color = if (tint == ErrorRed) ErrorRed else LocalAppColors.current.textPrimary)
    }
}

@Composable
fun TextEditDialog(
    title: String,
    hint: String,
    initial: String,
    maxLength: Int,
    singleLine: Boolean = true,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    val colors = LocalAppColors.current
    var text by remember { mutableStateOf(initial) }
    AppDialog(
        title,
        onDismiss,
        confirm = { DialogButton(stringResource(R.string.common_save)) { onSave(text.trim()) } },
        dismiss = { DialogButton(stringResource(R.string.common_cancel), onClick = onDismiss) },
    ) {
        OutlinedTextField(
            value = text,
            onValueChange = { if (it.length <= maxLength) text = it },
            placeholder = { Text(hint, color = colors.textMuted) },
            singleLine = singleLine,
            maxLines = if (singleLine) 1 else 3,
            supportingText = { Text("${text.length}/$maxLength", color = colors.textMuted) },
        )
    }
}

/** День рождения: 1900 — сегодня; на сервер уходит "YYYY-MM-DD". */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BirthdayPicker(current: String?, onDismiss: () -> Unit, onPicked: (String) -> Unit) {
    val initial = current?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: LocalDate.of(2000, 1, 1)
    val state = rememberDatePickerState(
        initialSelectedDateMillis = initial.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
        yearRange = 1900..LocalDate.now().year,
    )
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            DialogButton(stringResource(R.string.common_save)) {
                state.selectedDateMillis?.let { onPicked(Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate().toString()) }
            }
        },
        dismissButton = { DialogButton(stringResource(R.string.common_cancel), onClick = onDismiss) },
    ) {
        DatePicker(state)
    }
}
