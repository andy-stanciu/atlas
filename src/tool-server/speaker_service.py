import re
from dataclasses import dataclass
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Iterable

import torch
import torch.nn.functional as F
import torchaudio
from speechbrain.inference.speaker import EncoderClassifier
from werkzeug.datastructures import FileStorage

from config import (
    SPEAKER_KNOWN_THRESHOLD,
    SPEAKER_MAX_SAMPLES,
    SPEAKER_MIN_AUDIO_SECONDS,
    SPEAKER_MODEL_DIR,
    SPEAKER_MODEL_NAME,
    SPEAKER_REVIEW_THRESHOLD,
)
from repository import Repository


TARGET_SAMPLE_RATE = 16_000


class SpeakerError(ValueError):
    status_code = 400


class SpeakerAudioError(SpeakerError):
    status_code = 422


class SpeakerNotFoundError(SpeakerError):
    status_code = 404


class SpeakerAlreadyEnrolledError(SpeakerError):
    status_code = 409


@dataclass(frozen=True)
class EmbeddedAudio:
    embedding: list[float]
    duration_seconds: float


@dataclass(frozen=True)
class SpeakerMatch:
    status: str
    profile_id: int | None
    display_name: str | None
    similarity: float | None
    duration_seconds: float


class SpeakerService:
    def __init__(
        self,
        repository: Repository,
        model_name: str = SPEAKER_MODEL_NAME,
    ):
        self.repository = repository
        self.model_name = model_name

        SPEAKER_MODEL_DIR.mkdir(parents=True, exist_ok=True)

        self.classifier = EncoderClassifier.from_hparams(
            source=model_name,
            savedir=str(SPEAKER_MODEL_DIR),
            run_opts={"device": "cpu"},
        )

    def profiles_response(self) -> dict:
        return {
            "ok": True,
            "profiles": self.list_profiles(),
        }

    def enroll_from_uploads(
        self,
        display_name: str,
        uploads: Iterable[FileStorage],
    ) -> dict:
        audio_paths = self._save_uploads(uploads)

        try:
            if not audio_paths:
                raise SpeakerError(
                    "Provide at least one WAV file in multipart field 'audio'."
                )

            profile = self.enroll(display_name, audio_paths)

            return {
                "ok": True,
                "profile": profile,
            }
        finally:
            self._delete_temporary_files(audio_paths)

    def normalized_speaker_name(self, name: str) -> str:
        normalized = re.sub(r"\s+", " ", name.strip().lower())

        if not normalized:
            raise SpeakerError("The speaker name must contain letters or numbers.")

        return normalized

    def add_sample_from_uploads(
        self,
        profile_id: int,
        uploads: Iterable[FileStorage],
    ) -> dict:
        audio_paths = self._save_uploads(uploads)

        try:
            if len(audio_paths) != 1:
                raise SpeakerError(
                    "Provide exactly one WAV file in multipart field 'audio'."
                )

            profile = self.add_sample(profile_id, audio_paths[0])

            return {
                "ok": True,
                "profile": profile,
            }
        finally:
            self._delete_temporary_files(audio_paths)

    def identify_from_uploads(
        self,
        uploads: Iterable[FileStorage],
    ) -> dict:
        audio_paths = self._save_uploads(uploads)

        try:
            if len(audio_paths) != 1:
                raise SpeakerError(
                    "Provide exactly one WAV file in multipart field 'audio'."
                )

            match = self.identify(audio_paths[0])

            return {
                "ok": True,
                "status": match.status,
                "profile_id": match.profile_id,
                "display_name": match.display_name,
                "similarity": match.similarity,
                "duration_seconds": round(match.duration_seconds, 3),
            }
        finally:
            self._delete_temporary_files(audio_paths)

    def profile_id_for_name(self, name: str) -> str:
        profile_id = re.sub(
            r"[^a-z0-9]+",
            "-",
            name.strip().lower(),
        ).strip("-")

        if not profile_id:
            raise SpeakerError("The speaker name must contain letters or numbers.")

        return profile_id

    def enroll(
        self,
        display_name: str,
        audio_paths: list[Path],
    ) -> dict:
        display_name = display_name.strip()

        if not display_name:
            raise SpeakerError("Provide a non-empty speaker name.")

        if not audio_paths:
            raise SpeakerError("Provide at least one audio file.")

        embedded = [self.embed_file(path) for path in audio_paths]

        profile = self.repository.create_speaker_profile(
            display_name=display_name,
            normalized_name=self.normalized_speaker_name(display_name),
            samples=[
                {
                    "embedding": sample.embedding,
                    "duration_seconds": sample.duration_seconds,
                }
                for sample in embedded
            ],
            max_samples=SPEAKER_MAX_SAMPLES,
        )

        if profile is None:
            raise SpeakerAlreadyEnrolledError(
                f"'{display_name}' is already enrolled as a speaker."
            )

        return profile

    def add_sample(
        self,
        profile_id: int,
        audio_path: Path,
    ) -> dict:
        sample = self.embed_file(audio_path)

        profile = self.repository.add_speaker_sample(
            profile_id=profile_id,
            embedding=sample.embedding,
            duration_seconds=sample.duration_seconds,
            max_samples=SPEAKER_MAX_SAMPLES,
        )

        if profile is None:
            raise SpeakerNotFoundError(f"Speaker profile '{profile_id}' was not found.")

        return profile

    def list_profiles(self) -> list[dict]:
        return self.repository.list_speaker_profiles()

    def identify(
        self,
        audio_path: Path,
    ) -> SpeakerMatch:
        sample = self.embed_file(audio_path)
        embedding = torch.tensor(
            sample.embedding,
            dtype=torch.float32,
        )

        profiles = self.repository.speaker_profiles_for_matching()

        best_profile = None
        best_similarity = float("-inf")

        for profile in profiles:
            for stored in profile["samples"]:
                reference = torch.tensor(
                    stored["embedding"],
                    dtype=torch.float32,
                )
                reference = F.normalize(reference, p=2, dim=0)

                similarity = F.cosine_similarity(
                    embedding.unsqueeze(0),
                    reference.unsqueeze(0),
                ).item()

                if similarity > best_similarity:
                    best_similarity = similarity
                    best_profile = profile

        similarity = round(best_similarity, 4) if best_profile is not None else None

        if best_profile is None or best_similarity < SPEAKER_REVIEW_THRESHOLD:
            return SpeakerMatch(
                status="unknown",
                profile_id=None,
                display_name=None,
                similarity=similarity,
                duration_seconds=sample.duration_seconds,
            )

        if best_similarity < SPEAKER_KNOWN_THRESHOLD:
            return SpeakerMatch(
                status="uncertain",
                profile_id=best_profile["id"],
                display_name=best_profile["display_name"],
                similarity=similarity,
                duration_seconds=sample.duration_seconds,
            )

        return SpeakerMatch(
            status="known",
            profile_id=best_profile["id"],
            display_name=best_profile["display_name"],
            similarity=similarity,
            duration_seconds=sample.duration_seconds,
        )

    def embed_file(
        self,
        audio_path: Path,
    ) -> EmbeddedAudio:
        waveform, sample_rate = torchaudio.load(audio_path)

        if waveform.numel() == 0:
            raise SpeakerAudioError("Audio file contains no samples.")

        if waveform.shape[0] > 1:
            waveform = waveform.mean(dim=0, keepdim=True)

        if sample_rate != TARGET_SAMPLE_RATE:
            waveform = torchaudio.functional.resample(
                waveform,
                sample_rate,
                TARGET_SAMPLE_RATE,
            )

        duration_seconds = waveform.shape[1] / TARGET_SAMPLE_RATE

        if duration_seconds < SPEAKER_MIN_AUDIO_SECONDS:
            raise SpeakerAudioError(
                "Each audio clip must be at least "
                f"{SPEAKER_MIN_AUDIO_SECONDS:g} seconds."
            )

        waveform = waveform.to(dtype=torch.float32)

        with torch.inference_mode():
            embedding = self.classifier.encode_batch(waveform)

        embedding = embedding.squeeze().to(dtype=torch.float32)
        embedding = F.normalize(embedding, p=2, dim=0)

        return EmbeddedAudio(
            embedding=embedding.cpu().tolist(),
            duration_seconds=duration_seconds,
        )

    def _save_uploads(
        self,
        uploads: Iterable[FileStorage],
    ) -> list[Path]:
        paths = []

        for uploaded in uploads:
            if uploaded is None or not uploaded.filename:
                continue

            if Path(uploaded.filename).suffix.lower() != ".wav":
                raise SpeakerError("Only WAV audio is supported.")

            with NamedTemporaryFile(
                suffix=".wav",
                delete=False,
            ) as temporary_file:
                uploaded.save(temporary_file)
                paths.append(Path(temporary_file.name))

        return paths

    def _delete_temporary_files(
        self,
        paths: Iterable[Path],
    ) -> None:
        for path in paths:
            path.unlink(missing_ok=True)
